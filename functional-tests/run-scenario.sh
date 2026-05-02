#!/usr/bin/env bash
# Run a single scenario of the Valkey functional matrix against the
# already-created kind cluster.
#
# Usage:
#   ./run-scenario.sh <tls> <auth> <shard> <rep> <istio>
# Each arg is "on" or "off". Example:
#   ./run-scenario.sh off off on on on
# drives the "TLS off, auth off, shard on, rep on, Istio on" scenario.

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "${HERE}/lib.sh"

if (( $# != 5 )); then
    echo "usage: $0 <tls> <auth> <shard> <rep> <istio>   (each on|off)" >&2
    exit 2
fi

on_or_off() {
    case "$1" in
        on|off) return 0 ;;
        *) echo "expected 'on' or 'off', got: $1" >&2; return 1 ;;
    esac
}
for v in "$@"; do on_or_off "${v}"; done

TLS=$1; AUTH=$2; SHARD=$3; REP=$4; ISTIO=$5
SCENARIO="tls=${TLS} auth=${AUTH} shard=${SHARD} rep=${REP} istio=${ISTIO}"

is_on() { [[ $1 == on ]]; }

if is_on "${ISTIO}"; then
    TESTBENCH=${TESTBENCH_POD_INJECTED}
else
    TESTBENCH=${TESTBENCH_POD}
fi
testbench_exec() { testbench_exec_in "${TESTBENCH}" "$@"; }

# ---------------------------------------------------------------------------
# Build helm flags for this scenario.
# ---------------------------------------------------------------------------
helm_flags=()

if is_on "${ISTIO}"; then
    # Let Envoy get injected into every chart pod; turn on the chart's Istio
    # templates. The chart pins sidecar.istio.io/inject=true on every pod
    # itself, so no namespace-level label is required.
    helm_flags+=(--set=istio.enabled=true)
fi
# istio=off needs no extra flags: with the namespace unlabelled and
# istio.enabled=false, the chart emits zero mesh labels and pods stay out
# of both data planes.

if is_on "${AUTH}"; then
    helm_flags+=(
        --set=auth.enabled=true
        --set=auth.usersExistingSecret="${AUTH_SECRET}"
        --set=auth.aclUsers.default.permissions='~* &* +@all'
    )
fi

if is_on "${TLS}"; then
    helm_flags+=(
        --set=tls.enabled=true
        --set=tls.existingSecret="${TLS_SECRET}"
    )
fi

if is_on "${SHARD}"; then
    helm_flags+=(
        --set=cluster.enabled=true
        --set=cluster.persistence.size=1Gi
        --set=cluster.shards=3
    )
    if is_on "${REP}"; then
        helm_flags+=(--set=cluster.replicasPerShard=1)
        expected_node_count=6
    else
        helm_flags+=(--set=cluster.replicasPerShard=0)
        expected_node_count=3
    fi
elif is_on "${REP}"; then
    helm_flags+=(
        --set=replica.enabled=true
        --set=replica.persistence.size=1Gi
    )
    expected_node_count=0   # unused
else
    expected_node_count=0   # unused
fi

# ---------------------------------------------------------------------------
# Install.
# ---------------------------------------------------------------------------

# Register cleanup BEFORE `helm install`. If the install itself fails
# (timeout, post-install hook never ready, etc.) Helm leaves a "failed"
# release in the cluster that blocks every subsequent scenario with a
# `cannot reuse a name that is still in use` error. Trap-before-install
# ensures we always clean up, even on install failure.
cleanup() {
    local rc=$?
    log "Cleaning up scenario: ${SCENARIO}"
    hctl uninstall "${RELEASE}" 2>/dev/null || true
    kctl delete pvc --selector="app.kubernetes.io/instance=${RELEASE}" --ignore-not-found
    exit "${rc}"
}
trap cleanup EXIT

# Also scrub anything left behind by a prior scenario that crashed hard
# (SIGKILL, harness panic) without running its trap.
hctl uninstall "${RELEASE}" 2>/dev/null || true

log "Installing scenario: ${SCENARIO}"
hctl install "${RELEASE}" "${CHART_DIR}" "${helm_flags[@]}"

# ---------------------------------------------------------------------------
# Wait for pods to become ready.
# ---------------------------------------------------------------------------
log "Waiting for workload to be ready"
if is_on "${SHARD}"; then
    kctl rollout status "statefulset/${RELEASE}" --timeout=300s
    # The cluster-init Job is a post-install hook; wait for it to complete.
    kctl wait --for=condition=complete "job/${RELEASE}-cluster-init" --timeout=300s
elif is_on "${REP}"; then
    kctl rollout status "statefulset/${RELEASE}" --timeout=300s
else
    kctl rollout status "deployment/${RELEASE}" --timeout=300s
fi

# ---------------------------------------------------------------------------
# Build the canonical "working" valkey-cli argv for this scenario.
# ---------------------------------------------------------------------------
cli_args_good=(valkey-cli -h "valkey.${NAMESPACE}.svc.cluster.local" --no-auth-warning)
if is_on "${AUTH}"; then
    cli_args_good+=(-a "${AUTH_PASSWORD}")
fi
if is_on "${TLS}"; then
    cli_args_good+=(--tls --cacert /tls/ca.crt)
fi

# ---------------------------------------------------------------------------
# Assertions.
# ---------------------------------------------------------------------------
fail() { echo "FAIL: $*" >&2; exit 1; }

assert_eq() {
    local expected=$1 actual=$2 what=$3
    if [[ ${actual} != "${expected}" ]]; then
        fail "${what}: expected '${expected}', got '${actual}'"
    fi
}

# Istio resources: PeerAuthentication + DestinationRule (headless DR only exists
# in replica / cluster mode) should be present iff istio=on.
if is_on "${ISTIO}"; then
    log "Istio check: chart-owned resources must exist"
    kctl get peerauthentication "${RELEASE}" >/dev/null \
        || fail "PeerAuthentication/${RELEASE} missing"
    kctl get destinationrule "${RELEASE}" >/dev/null \
        || fail "DestinationRule/${RELEASE} missing"
    if is_on "${SHARD}" || is_on "${REP}"; then
        kctl get destinationrule "${RELEASE}-headless" >/dev/null \
            || fail "DestinationRule/${RELEASE}-headless missing"
    fi

    # Chart pods must actually have the Envoy sidecar. Istio >=1.29 injects it
    # as a native sidecar (initContainer with restartPolicy=Always), so check
    # both containers and initContainers.
    pod=$(kctl get pod -l "app.kubernetes.io/instance=${RELEASE}" \
        -o jsonpath='{.items[0].metadata.name}')
    if ! kctl get pod "${pod}" \
         -o jsonpath='{.spec.containers[*].name} {.spec.initContainers[*].name}' \
         | tr ' ' '\n' | grep -Fxq istio-proxy; then
        fail "pod ${pod} has no istio-proxy container"
    fi
else
    log "Istio check: chart-owned resources must be absent"
    if kctl get peerauthentication "${RELEASE}" >/dev/null 2>&1; then
        fail "PeerAuthentication/${RELEASE} should not exist when istio=off"
    fi
    if kctl get destinationrule "${RELEASE}" >/dev/null 2>&1; then
        fail "DestinationRule/${RELEASE} should not exist when istio=off"
    fi
fi

# Positive: the fully-correct invocation should succeed.
log "Positive check"
if is_on "${SHARD}"; then
    # Even after the cluster-init Job completes, gossip needs a few seconds to converge
    # — each node updates `cluster_state` only after it sees the others. Poll for that.
    state=fail
    for _ in $(seq 1 30); do
        state=$(testbench_exec "${cli_args_good[@]}" cluster info | awk -F: '/^cluster_state:/{print $2}' | tr -d '\r\n')
        [[ ${state} == ok ]] && break
        sleep 2
    done
    assert_eq "ok" "${state}" "cluster_state"

    # Inspect the topology: exact count + master/slave split.
    nodes=$(testbench_exec "${cli_args_good[@]}" cluster nodes)
    actual_nodes=$(printf '%s\n' "${nodes}" | sed '/^$/d' | wc -l | tr -d ' ')
    assert_eq "${expected_node_count}" "${actual_nodes}" "cluster node count"

    master_count=$(printf '%s\n' "${nodes}" | grep -c 'master' || true)
    assert_eq "3" "${master_count}" "master count"

    if is_on "${REP}"; then
        slave_count=$(printf '%s\n' "${nodes}" | grep -c 'slave' || true)
        assert_eq "3" "${slave_count}" "slave count"
    fi
else
    pong=$(testbench_exec "${cli_args_good[@]}" ping | tr -d '\r\n')
    assert_eq "PONG" "${pong}" "ping"
fi

# Negative — auth. No password should be rejected with NOAUTH.
if is_on "${AUTH}"; then
    log "Negative check: missing password must be rejected"
    cli_args_noauth=(valkey-cli -h "valkey.${NAMESPACE}.svc.cluster.local" --no-auth-warning)
    if is_on "${TLS}"; then
        cli_args_noauth+=(--tls --cacert /tls/ca.crt)
    fi
    if is_on "${SHARD}"; then
        probe_cmd=(cluster info)
    else
        probe_cmd=(ping)
    fi
    set +e
    out=$(testbench_exec "${cli_args_noauth[@]}" "${probe_cmd[@]}" 2>&1)
    rc=$?
    set -e
    if ! grep -qi 'NOAUTH' <<<"${out}"; then
        fail "expected NOAUTH error, got (rc=${rc}): ${out}"
    fi
fi

# Negative — TLS. No --tls at all, and --tls without the CA, must both fail.
if is_on "${TLS}"; then
    log "Negative check: plaintext client against TLS server must fail"
    cli_args_plaintext=(valkey-cli -h "valkey.${NAMESPACE}.svc.cluster.local" --no-auth-warning)
    if is_on "${AUTH}"; then cli_args_plaintext+=(-a "${AUTH_PASSWORD}"); fi
    if is_on "${SHARD}"; then probe_cmd=(cluster info); else probe_cmd=(ping); fi
    set +e
    out=$(testbench_exec "${cli_args_plaintext[@]}" "${probe_cmd[@]}" 2>&1)
    rc=$?
    set -e
    if (( rc == 0 )); then
        fail "plaintext client should have failed but succeeded: ${out}"
    fi

    log "Negative check: TLS client without CA must fail to verify"
    cli_args_nocacert=(valkey-cli -h "valkey.${NAMESPACE}.svc.cluster.local" --tls --no-auth-warning)
    if is_on "${AUTH}"; then cli_args_nocacert+=(-a "${AUTH_PASSWORD}"); fi
    set +e
    out=$(testbench_exec "${cli_args_nocacert[@]}" "${probe_cmd[@]}" 2>&1)
    rc=$?
    set -e
    if (( rc == 0 )) || ! grep -qi 'certificate verify failed' <<<"${out}"; then
        fail "expected 'certificate verify failed', got (rc=${rc}): ${out}"
    fi
fi

log "PASS: ${SCENARIO}"
