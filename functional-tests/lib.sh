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
# Three testbenches, covering every shape of mesh participation:
#   valkey-testbench          — never gets an Envoy sidecar (istio=off
#                               scenarios, or when Istio isn't installed at
#                               all). Opts out of both sidecar injection
#                               and ambient capture.
#   valkey-testbench-injected — sidecar-injected (istio=on, mode=sidecar).
#   valkey-testbench-ambient  — ambient-enrolled (istio=on, mode=ambient):
#                               no sidecar, ztunnel captures its traffic so
#                               it presents the expected SPIFFE identity to
#                               Valkey pods' AuthorizationPolicy.
TESTBENCH_POD=valkey-testbench
TESTBENCH_POD_INJECTED=valkey-testbench-injected
TESTBENCH_POD_AMBIENT=valkey-testbench-ambient
# Deliberately hostile: spaces, shell metacharacters ($, `, &, !), a backslash,
# and a double-quote. Every auth=on scenario then exercises both layers of
# quoting on the chart side:
#   - the init container's ACL hash pipe (printf %s | sha256sum)
#   - the masterauth line in valkey.conf (must be quoted+escaped)
#   - the cluster-init Job's REDISCLI_AUTH path
#   - the helm-test pod's `cat /valkey-auth/...-password | xargs valkey-cli -a`
# Keeping these in one place means every future auth=on scenario inherits the
# coverage for free.
AUTH_PASSWORD='p@ss w/ spaces & $chars `backticks` "quoted" \backslash'

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

# Whether the cluster has Istio's ambient data plane (ztunnel DaemonSet)
# installed. Scenarios that require ambient exit-skip if this returns false.
istio_ambient_installed() {
    kubectl --context="${KUBE_CONTEXT}" -n "${ISTIO_NAMESPACE}" \
        get daemonset ztunnel >/dev/null 2>&1
}
