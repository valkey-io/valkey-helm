#!/usr/bin/env bash
# Bring up the kind cluster, install Istio (demo profile), and create the
# shared fixtures (auth secret, TLS secret, two testbench pods) used by
# every scenario.

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "${HERE}/lib.sh"

log "Creating kind cluster ${CLUSTER_NAME}"
if kind get clusters | grep -Fxq "${CLUSTER_NAME}"; then
    echo "kind cluster '${CLUSTER_NAME}' already exists; reusing"
else
    kind create cluster --config "${HERE}/kind-config.yaml" --wait 120s
fi

log "Installing Istio (ambient profile)"
if istio_installed; then
    echo "istio-system namespace already exists; assuming Istio is installed"
else
    # `ambient` ships istiod + the ambient data plane (istio-cni DaemonSet
    # for iptables redirection, ztunnel DaemonSet for node-local HBONE
    # mTLS). It also installs the sidecar injection webhook, so classic
    # sidecar-mode pods still work on the same cluster — we can run both
    # the sidecar matrix and the ambient regressions against one install.
    istioctl install --context="${KUBE_CONTEXT}" \
        --set profile=ambient --skip-confirmation
fi

# Wait for the ambient data plane to be live before launching testbenches.
# Without this, the first few ambient scenarios race ztunnel startup and
# the testbench gets no HBONE wrapping.
if istio_ambient_installed; then
    log "Waiting for ztunnel DaemonSet to be ready"
    kubectl --context="${KUBE_CONTEXT}" -n "${ISTIO_NAMESPACE}" \
        rollout status daemonset/ztunnel --timeout=180s
fi

log "Enabling sidecar injection on namespace ${NAMESPACE}"
# Label idempotently — `kubectl label --overwrite` works whether or not the
# label exists. Sidecar and ambient opt-in are independent: the namespace
# carries the sidecar webhook label, and individual pods opt into ambient
# via the pod-level `istio.io/dataplane-mode` label (the Helm chart sets
# this on every Valkey pod when istio.mode=ambient).
kubectl --context="${KUBE_CONTEXT}" label namespace "${NAMESPACE}" \
    istio-injection=enabled --overwrite

log "Creating ${AUTH_SECRET} secret"
kctl delete secret "${AUTH_SECRET}" --ignore-not-found
kctl create secret generic "${AUTH_SECRET}" \
    --from-literal="default=${AUTH_PASSWORD}"

log "Generating self-signed TLS material"
CERT_DIR=$(mktemp -d)
trap 'rm -rf -- "${CERT_DIR}"' EXIT

# CA
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "${CERT_DIR}/valkey-ca.key" \
    -out    "${CERT_DIR}/valkey-ca.crt" \
    -subj /CN=valkey-ca 2>/dev/null

# Server CSR with SANs the chart's pods present on
openssl req -nodes -newkey rsa:2048 \
    -keyout "${CERT_DIR}/valkey-server.key" \
    -out    "${CERT_DIR}/valkey-server.csr" \
    -subj "/CN=valkey.${NAMESPACE}.svc.cluster.local" \
    -addext "subjectAltName=DNS:valkey.${NAMESPACE}.svc.cluster.local,DNS:valkey-headless.${NAMESPACE}.svc.cluster.local,DNS:*.valkey-headless.${NAMESPACE}.svc.cluster.local" \
    2>/dev/null

openssl x509 -req \
    -in "${CERT_DIR}/valkey-server.csr" \
    -CA "${CERT_DIR}/valkey-ca.crt" \
    -CAkey "${CERT_DIR}/valkey-ca.key" \
    -CAcreateserial \
    -out "${CERT_DIR}/valkey-server.crt" \
    -days 365 \
    -copy_extensions copyall \
    2>/dev/null

log "Creating ${TLS_SECRET} secret"
kctl delete secret "${TLS_SECRET}" --ignore-not-found
kctl create secret generic "${TLS_SECRET}" \
    --from-file="server.crt=${CERT_DIR}/valkey-server.crt" \
    --from-file="server.key=${CERT_DIR}/valkey-server.key" \
    --from-file="ca.crt=${CERT_DIR}/valkey-ca.crt"

# ---------------------------------------------------------------------------
# Testbench pods. Three flavours:
#   valkey-testbench          — never injected (sidecar.istio.io/inject=false).
#                               Also opts out of ambient capture so the
#                               default testbench is a plain pod regardless
#                               of mesh mode.
#   valkey-testbench-injected — Envoy sidecar, used for istio=on mode=sidecar.
#   valkey-testbench-ambient  — ambient-enrolled (no sidecar, ztunnel-wrapped),
#                               used for istio=on mode=ambient.
# Each flavour is a POD-level opt-in/out so one cluster (which has both data
# planes installed by the `ambient` profile) can host all three side by side.
# ---------------------------------------------------------------------------
# $1: pod name
# $2: flavour (plain|sidecar|ambient)
launch_testbench() {
    local pod=$1 flavour=$2 overrides labels
    case "${flavour}" in
        plain)
            # Out of both meshes: classic no-Istio behaviour for istio=off.
            labels='sidecar.istio.io/inject=false,istio.io/dataplane-mode=none'
            ;;
        sidecar)
            labels='sidecar.istio.io/inject=true'
            ;;
        ambient)
            # Pod-level ambient opt-in. Overrides the namespace's
            # istio-injection=enabled so this pod gets ztunnel, not Envoy.
            labels='sidecar.istio.io/inject=false,istio.io/dataplane-mode=ambient'
            ;;
        *)
            echo "launch_testbench: unknown flavour ${flavour}" >&2
            return 2
            ;;
    esac
    overrides='{
      "spec": {
        "containers": [{
          "name": "'"${pod}"'",
          "image": "valkey/valkey:9.0.1",
          "command": ["sleep", "infinity"],
          "volumeMounts": [{"name": "tls", "mountPath": "/tls", "readOnly": true}]
        }],
        "volumes": [{
          "name": "tls",
          "secret": {"secretName": "'"${TLS_SECRET}"'"}
        }]
      }
    }'
    kctl delete pod "${pod}" --ignore-not-found --wait=true
    kctl run "${pod}" \
        --image=valkey/valkey:9.0.1 \
        --labels="${labels}" \
        --restart=Never \
        --overrides="${overrides}" \
        --command -- sleep infinity
    wait_for_testbench "${pod}"
}

log "Launching ${TESTBENCH_POD} (no mesh)"
launch_testbench "${TESTBENCH_POD}" plain

log "Launching ${TESTBENCH_POD_INJECTED} (Envoy sidecar)"
launch_testbench "${TESTBENCH_POD_INJECTED}" sidecar

if istio_ambient_installed; then
    log "Launching ${TESTBENCH_POD_AMBIENT} (ambient / ztunnel)"
    launch_testbench "${TESTBENCH_POD_AMBIENT}" ambient
else
    log "Skipping ${TESTBENCH_POD_AMBIENT} — ambient data plane not installed"
fi

log "Setup complete"
