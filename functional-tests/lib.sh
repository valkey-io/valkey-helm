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
# Two testbenches: one never gets an Envoy sidecar (istio=off scenarios, or when
# Istio isn't installed at all), one does (istio=on scenarios).
TESTBENCH_POD=valkey-testbench
TESTBENCH_POD_INJECTED=valkey-testbench-injected
AUTH_PASSWORD=password

ISTIO_NAMESPACE=istio-system

log() { printf '=== %s ===\n' "$*"; }

kctl() { kubectl --context="${KUBE_CONTEXT}" --namespace="${NAMESPACE}" "$@"; }
hctl() { helm  --kube-context="${KUBE_CONTEXT}" --namespace="${NAMESPACE}" "$@"; }

# kubectl exec into a testbench. First arg is the pod name; rest is the command.
testbench_exec_in() {
    local pod=$1; shift
    kctl exec "${pod}" -c "${pod}" -- "$@"
}

wait_for_testbench() {
    local pod=$1
    kctl wait --for=condition=Ready "pod/${pod}" --timeout=180s
}

istio_installed() {
    kubectl --context="${KUBE_CONTEXT}" get namespace "${ISTIO_NAMESPACE}" >/dev/null 2>&1
}
