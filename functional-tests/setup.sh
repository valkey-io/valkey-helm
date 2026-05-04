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

# Namespace-level Istio injection intentionally NOT set. The chart now
# carries per-pod `sidecar.istio.io/inject` and `istio.io/dataplane-mode`
# labels derived from `istio.enabled` + `istio.mode`, so every workload
# opts in or out explicitly at the pod layer. Labelling the namespace
# `istio-injection=enabled` on top would (a) pull every istio=off pod
# into the sidecar data plane — since namespace injection is inherited
# unless each pod stamps `sidecar.istio.io/inject=false` to veto it —
# and (b) blur which layer is actually responsible for mesh capture
# when troubleshooting. Keep the decision at the pod level, the same as
# how the chart ships to real operators.
log "Namespace ${NAMESPACE} left unlabelled — chart controls mesh opt-in at the pod level"
kubectl --context="${KUBE_CONTEXT}" label namespace "${NAMESPACE}" \
    istio-injection- istio.io/dataplane-mode- 2>/dev/null || true

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
# Testbench pods. Three flavours, each expressing its mesh intent via
# POD-level labels (the namespace is intentionally unlabelled — see the
# comment at the sidecar-injection step above). The chart's Valkey pods
# take the same pod-level approach, so the tests exercise the same opt-in
# path operators use in production.
#
#   valkey-testbench          — out of both meshes. Used for istio=off
#                               scenarios; no mesh labels emitted.
#   valkey-testbench-injected — Envoy sidecar via per-pod inject=true.
#                               Used for istio=on mode=sidecar.
#   valkey-testbench-ambient  — ztunnel-wrapped via
#                               istio.io/dataplane-mode=ambient.
#                               Used for istio=on mode=ambient.
# ---------------------------------------------------------------------------
# $1: pod name
# $2: flavour (plain|sidecar|ambient)
launch_testbench() {
    local pod=$1 flavour=$2 overrides labels
    case "${flavour}" in
        plain)
            # No mesh labels: with the namespace unlabelled, the default is
            # already "out of both meshes".
            labels=''
            ;;
        sidecar)
            labels='sidecar.istio.io/inject=true'
            ;;
        ambient)
            labels='istio.io/dataplane-mode=ambient'
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
    local label_args=()
    [[ -n ${labels} ]] && label_args=(--labels="${labels}")
    kctl delete pod "${pod}" --ignore-not-found --wait=true
    kctl run "${pod}" \
        --image=valkey/valkey:9.0.1 \
        "${label_args[@]}" \
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
