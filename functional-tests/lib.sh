# Shared helpers for Valkey functional tests.
# Sourced by every script under functional-tests/.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${HERE}/.." && pwd)
CHART_DIR=${REPO_ROOT}/valkey

CLUSTER_NAME=${VALKEY_KIND_CLUSTER:-valkey-functional}
KUBE_CONTEXT=kind-${CLUSTER_NAME}
NAMESPACE=${VALKEY_FUNCTIONAL_NAMESPACE:-default}
RELEASE=${VALKEY_RELEASE:-valkey}

AUTH_SECRET=valkey-auth
TLS_SECRET=valkey-tls
TESTBENCH_POD=valkey-testbench
AUTH_PASSWORD=password

log() { printf '=== %s ===\n' "$*"; }

kctl() { kubectl --context="${KUBE_CONTEXT}" --namespace="${NAMESPACE}" "$@"; }
hctl() { helm  --kube-context="${KUBE_CONTEXT}" --namespace="${NAMESPACE}" "$@"; }

# kubectl exec into the testbench. Pipes stderr through so failures are legible.
testbench_exec() { kctl exec "${TESTBENCH_POD}" -- "$@"; }

wait_for_testbench() {
    kctl wait --for=condition=Ready "pod/${TESTBENCH_POD}" --timeout=120s
}
