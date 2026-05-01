#!/usr/bin/env bash
# Bring up the kind cluster and create the shared fixtures (auth secret,
# TLS secret, testbench pod) used by every scenario.

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "${HERE}/lib.sh"

log "Creating kind cluster ${CLUSTER_NAME}"
if kind get clusters | grep -Fxq "${CLUSTER_NAME}"; then
    echo "kind cluster '${CLUSTER_NAME}' already exists; reusing"
else
    kind create cluster --config "${HERE}/kind-config.yaml" --wait 120s
fi

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

log "Launching ${TESTBENCH_POD}"
kctl delete pod "${TESTBENCH_POD}" --ignore-not-found --wait=true
kctl run "${TESTBENCH_POD}" \
    --image=valkey/valkey:9.0.1 \
    --labels='sidecar.istio.io/inject=false' \
    --restart=Never \
    --overrides='{
      "spec": {
        "containers": [{
          "name": "'"${TESTBENCH_POD}"'",
          "image": "valkey/valkey:9.0.1",
          "command": ["sleep", "infinity"],
          "volumeMounts": [{
            "name": "tls",
            "mountPath": "/tls",
            "readOnly": true
          }]
        }],
        "volumes": [{
          "name": "tls",
          "secret": {"secretName": "'"${TLS_SECRET}"'"}
        }]
      }
    }' \
    --command -- sleep infinity
wait_for_testbench

log "Setup complete"
