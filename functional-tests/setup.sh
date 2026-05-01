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

log "Installing Istio (demo profile)"
if istio_installed; then
    echo "istio-system namespace already exists; assuming Istio is installed"
else
    # `demo` gives us istiod + an ingress/egress gateway. We only need istiod,
    # but the profile is the simplest path and adds no meaningful overhead.
    istioctl install --context="${KUBE_CONTEXT}" --set profile=demo --skip-confirmation
fi

log "Enabling sidecar injection on namespace ${NAMESPACE}"
# Label idempotently — `kubectl label --overwrite` works whether or not the
# label exists.
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
# Testbench pods. Two flavours:
#   valkey-testbench          — never injected (sidecar.istio.io/inject=false)
#   valkey-testbench-injected — injected, used for istio=on scenarios
# ---------------------------------------------------------------------------
launch_testbench() {
    local pod=$1 inject=$2 overrides
    local labels
    if [[ ${inject} == "false" ]]; then
        labels='sidecar.istio.io/inject=false'
    else
        labels='sidecar.istio.io/inject=true'
    fi
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

log "Launching ${TESTBENCH_POD} (no sidecar)"
launch_testbench "${TESTBENCH_POD}" false

log "Launching ${TESTBENCH_POD_INJECTED} (with Envoy sidecar)"
launch_testbench "${TESTBENCH_POD_INJECTED}" true

log "Setup complete"
