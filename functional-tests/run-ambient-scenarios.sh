#!/usr/bin/env bash
# Ambient-mesh regressions. Mirrors the core sidecar scenarios but flips
# istio.mode=ambient so ztunnel — not Envoy — carries the Valkey pod traffic.
#
# Rather than expanding the 32-scenario matrix to 96 (sidecar × ambient × on),
# this file concentrates on what's actually different in ambient:
#   1) Pods have no sidecar but still speak mTLS (via ztunnel HBONE).
#   2) DestinationRule is intentionally absent.
#   3) AuthorizationPolicy at L4 (ztunnel) scopes the cluster-bus port to
#      same-release SPIFFE principals, preventing cross-release CLUSTER MEET.
#   4) No traffic.sidecar.istio.io/excludePorts annotations — they're
#      sidecar-only and must not leak into the rendered pods.
#
# The sidecar matrix in run-all.sh already covers TLS/auth/shard/rep combos.
# Ambient is meaningful around the data-plane shape, so we sample one
# standalone, one replica, one cluster scenario — each with auth+TLS on to
# exercise the full ACL and mTLS paths.

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "${HERE}/lib.sh"

if ! istio_ambient_installed; then
    log "Skipping ambient scenarios — ztunnel not installed"
    exit 0
fi

RESULTS=()
pass() { RESULTS+=("PASS: $1"); }
fail() { RESULTS+=("FAIL: $1: $2"); return 1; }

cleanup_release() {
    hctl uninstall "${RELEASE}" 2>/dev/null || true
    kctl delete pvc --selector="app.kubernetes.io/instance=${RELEASE}" --ignore-not-found >/dev/null
}

testbench_ambient_exec() {
    testbench_exec_in "${TESTBENCH_POD_AMBIENT}" "$@"
}

# Assert the Valkey pod has NO Envoy sidecar (ambient-mode proof).
assert_no_sidecar() {
    local pod=$1 name=$2
    if kctl get pod "${pod}" \
         -o jsonpath='{.spec.containers[*].name} {.spec.initContainers[*].name}' \
         | tr ' ' '\n' | grep -Fxq istio-proxy; then
        fail "${name}" "pod ${pod} has an istio-proxy container in ambient mode"
        return 1
    fi
    return 0
}

# Assert the Valkey pod carries the ambient data-plane label.
assert_ambient_label() {
    local pod=$1 name=$2 mode
    mode=$(kctl get pod "${pod}" \
        -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}')
    if [[ ${mode} != ambient ]]; then
        fail "${name}" "pod ${pod} has istio.io/dataplane-mode=${mode:-<unset>}, want ambient"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Scenario 1: standalone + ambient. Proves the basic ambient path.
# ---------------------------------------------------------------------------
scenario_standalone_ambient() {
    local name="ambient: standalone pings via ztunnel mTLS"
    log "SCENARIO: ${name}"
    cleanup_release

    if ! hctl install "${RELEASE}" "${CHART_DIR}" \
            --set=istio.enabled=true \
            --set=istio.mode=ambient \
            --wait --timeout=180s >/dev/null; then
        fail "${name}" "helm install failed"; return
    fi

    local pod
    pod=$(kctl get pod -l "app.kubernetes.io/instance=${RELEASE}" \
        -o jsonpath='{.items[0].metadata.name}')

    assert_no_sidecar "${pod}" "${name}" || return
    assert_ambient_label "${pod}" "${name}" || return

    # DestinationRule must NOT be rendered in ambient mode.
    if kctl get destinationrule "${RELEASE}" >/dev/null 2>&1; then
        fail "${name}" "DestinationRule/${RELEASE} must not exist in ambient mode"
        return
    fi

    # PeerAuthentication must be present (enforced by ztunnel).
    if ! kctl get peerauthentication "${RELEASE}" >/dev/null 2>&1; then
        fail "${name}" "PeerAuthentication/${RELEASE} missing"
        return
    fi

    # Connectivity from the ambient-enrolled testbench.
    local pong
    pong=$(testbench_ambient_exec \
        valkey-cli -h "valkey.${NAMESPACE}.svc.cluster.local" ping | tr -d '\r\n')
    if [[ ${pong} != PONG ]]; then
        fail "${name}" "expected PONG, got '${pong}'"; return
    fi

    cleanup_release
    pass "${name}"
}

# ---------------------------------------------------------------------------
# Scenario 2: cluster + ambient. Exercises the multi-pod case, the
# AuthorizationPolicy gate on the bus port, and the absence of the
# sidecar-specific exclude* annotations on the StatefulSet.
# ---------------------------------------------------------------------------
scenario_cluster_ambient() {
    local name="ambient: cluster mode converges with AuthorizationPolicy gating bus port"
    log "SCENARIO: ${name}"
    cleanup_release

    if ! hctl install "${RELEASE}" "${CHART_DIR}" \
            --set=istio.enabled=true \
            --set=istio.mode=ambient \
            --set=cluster.enabled=true \
            --set=cluster.shards=3 \
            --set=cluster.replicasPerShard=0 \
            --set=cluster.persistence.size=100Mi \
            --wait --timeout=300s >/dev/null; then
        fail "${name}" "helm install failed"; return
    fi
    kctl wait --for=condition=complete "job/${RELEASE}-cluster-init" --timeout=300s >/dev/null

    local pod
    pod=$(kctl get pod -l "app.kubernetes.io/instance=${RELEASE}" \
        -o jsonpath='{.items[0].metadata.name}')

    assert_no_sidecar "${pod}" "${name}" || return
    assert_ambient_label "${pod}" "${name}" || return

    # StatefulSet must NOT carry the sidecar-only exclude* annotations — if
    # it does, the intent/reality have drifted (ambient has no Envoy to
    # exclude ports from, and these leak would-be sidecar coupling into the
    # ambient path).
    local excl
    excl=$(kctl get statefulset "${RELEASE}" \
        -o jsonpath='{.spec.template.metadata.annotations.traffic\.sidecar\.istio\.io/excludeInboundPorts}')
    if [[ -n ${excl} ]]; then
        fail "${name}" "traffic.sidecar.istio.io/excludeInboundPorts=${excl} leaked into ambient pod"
        return
    fi

    # AuthorizationPolicy must be present and scoped to the release principal.
    local principals
    principals=$(kctl get authorizationpolicy "${RELEASE}-cluster-bus" \
        -o jsonpath='{.spec.rules[0].from[0].source.principals[*]}' 2>/dev/null)
    if [[ ${principals} != *"/sa/${RELEASE}"* ]]; then
        fail "${name}" "AuthorizationPolicy principals=${principals} (want .../sa/${RELEASE}*)"
        return
    fi

    # Cluster must converge.
    local state
    for _ in $(seq 1 30); do
        state=$(testbench_ambient_exec \
            valkey-cli -h "valkey.${NAMESPACE}.svc.cluster.local" \
            cluster info 2>/dev/null | awk -F: '/^cluster_state:/{print $2}' | tr -d '\r\n')
        [[ ${state} == ok ]] && break
        sleep 2
    done
    if [[ ${state} != ok ]]; then
        fail "${name}" "cluster_state=${state:-<empty>}, want ok"; return
    fi

    cleanup_release
    pass "${name}"
}

# ---------------------------------------------------------------------------
# Scenario 3: auth + TLS + cluster + ambient. End-to-end coverage of the
# app-level crypto (TLS) + ACL auth paths running INSIDE ztunnel's HBONE
# mTLS wrapper. If any of these layers fight, this scenario catches it.
# ---------------------------------------------------------------------------
scenario_cluster_ambient_tls_auth() {
    local name="ambient: cluster+auth+TLS works end-to-end through ztunnel"
    log "SCENARIO: ${name}"
    cleanup_release

    if ! hctl install "${RELEASE}" "${CHART_DIR}" \
            --set=istio.enabled=true \
            --set=istio.mode=ambient \
            --set=tls.enabled=true \
            --set=tls.existingSecret="${TLS_SECRET}" \
            --set=auth.enabled=true \
            --set=auth.usersExistingSecret="${AUTH_SECRET}" \
            --set=auth.aclUsers.default.permissions='~* &* +@all' \
            --set=cluster.enabled=true \
            --set=cluster.shards=3 \
            --set=cluster.replicasPerShard=0 \
            --set=cluster.persistence.size=100Mi \
            --wait --timeout=300s >/dev/null; then
        fail "${name}" "helm install failed"; return
    fi
    kctl wait --for=condition=complete "job/${RELEASE}-cluster-init" --timeout=300s >/dev/null

    # Positive check: authenticated TLS client converges.
    local state
    for _ in $(seq 1 30); do
        state=$(testbench_ambient_exec valkey-cli \
            -h "valkey.${NAMESPACE}.svc.cluster.local" \
            --no-auth-warning \
            -a "${AUTH_PASSWORD}" \
            --tls --cacert /tls/ca.crt \
            cluster info 2>/dev/null | awk -F: '/^cluster_state:/{print $2}' | tr -d '\r\n')
        [[ ${state} == ok ]] && break
        sleep 2
    done
    if [[ ${state} != ok ]]; then
        fail "${name}" "cluster_state=${state:-<empty>}, want ok"; return
    fi

    # Negative: missing auth still rejected even through ztunnel.
    local out rc
    set +e
    out=$(testbench_ambient_exec valkey-cli \
        -h "valkey.${NAMESPACE}.svc.cluster.local" \
        --no-auth-warning --tls --cacert /tls/ca.crt \
        cluster info 2>&1)
    rc=$?
    set -e
    if ! grep -qi 'NOAUTH' <<<"${out}"; then
        fail "${name}" "expected NOAUTH, got (rc=${rc}): ${out}"; return
    fi

    cleanup_release
    pass "${name}"
}

# ---------------------------------------------------------------------------
# Scenario 4: cross-release CLUSTER MEET must be blocked by the ambient
# AuthorizationPolicy. Analogous to scenario_two_clusters_isolated in the
# sidecar extras but driven at L4 via ztunnel rather than by NetworkPolicy.
#
# We install two cluster-mode releases in the same namespace, both in
# ambient mode with the chart's Kubernetes NetworkPolicy isolation turned
# OFF (`cluster.isolation.enabled=false`) — so the ONLY thing stopping the
# merge is the AuthorizationPolicy. Then we fire a MEET from A targeting B,
# wait out the node-timeout, and assert each cluster still sees 3 nodes.
# ---------------------------------------------------------------------------
install_ambient_cluster() {
    local release=$1
    hctl install "${release}" "${CHART_DIR}" \
        --set=istio.enabled=true \
        --set=istio.mode=ambient \
        --set=cluster.enabled=true \
        --set=cluster.persistence.size=100Mi \
        --set=cluster.shards=3 \
        --set=cluster.replicasPerShard=0 \
        --set=cluster.isolation.enabled=false \
        --wait --timeout=300s >/dev/null
}

count_cluster_nodes_ambient() {
    local release=$1
    kctl exec "${release}-0" -c "${release}" -- sh -c \
        "valkey-cli cluster nodes 2>/dev/null | awk 'NF {print \$1}' | sort -u | wc -l" \
        2>/dev/null | tr -d '[:space:]' || echo 0
}

poison_meet_ambient() {
    local src_release=$1 dst_release=$2 dst_ip
    dst_ip=$(kctl get pod "${dst_release}-0" -o jsonpath='{.status.podIP}')
    [[ -n ${dst_ip} ]] || return 1
    kctl exec "${src_release}-0" -c "${src_release}" -- \
        valkey-cli cluster meet "${dst_ip}" 6379 >/dev/null 2>&1 || true
}

cleanup_ambient_pair() {
    hctl uninstall valkey-amb-a 2>/dev/null || true
    hctl uninstall valkey-amb-b 2>/dev/null || true
    kctl delete pvc --selector='app.kubernetes.io/instance=valkey-amb-a' --ignore-not-found >/dev/null
    kctl delete pvc --selector='app.kubernetes.io/instance=valkey-amb-b' --ignore-not-found >/dev/null
}

scenario_ambient_authz_blocks_cross_release_meet() {
    local name="ambient: AuthorizationPolicy blocks cross-release CLUSTER MEET"
    log "SCENARIO: ${name}"
    cleanup_ambient_pair

    if ! install_ambient_cluster valkey-amb-a; then
        fail "${name}" "install of valkey-amb-a failed"; cleanup_ambient_pair; return
    fi
    if ! install_ambient_cluster valkey-amb-b; then
        fail "${name}" "install of valkey-amb-b failed"; cleanup_ambient_pair; return
    fi
    kctl wait --for=condition=complete job/valkey-amb-a-cluster-init --timeout=300s >/dev/null
    kctl wait --for=condition=complete job/valkey-amb-b-cluster-init --timeout=300s >/dev/null

    local a_before b_before
    a_before=$(count_cluster_nodes_ambient valkey-amb-a)
    b_before=$(count_cluster_nodes_ambient valkey-amb-b)
    if [[ ${a_before} != 3 || ${b_before} != 3 ]]; then
        fail "${name}" "baseline wrong (a=${a_before}, b=${b_before}; want 3+3)"
        cleanup_ambient_pair; return
    fi

    poison_meet_ambient valkey-amb-a valkey-amb-b

    # Same rationale as the sidecar-mode isolation test: after the MEET,
    # `cluster nodes` on A briefly shows 4 as a handshake placeholder. The
    # real signal is post-settle. Node-timeout defaults to 15s; give it
    # multiple intervals.
    sleep 45

    local a_after b_after
    a_after=$(count_cluster_nodes_ambient valkey-amb-a)
    b_after=$(count_cluster_nodes_ambient valkey-amb-b)
    if [[ ${a_after} != 3 || ${b_after} != 3 ]]; then
        fail "${name}" "clusters merged despite AuthorizationPolicy (a=${a_after}, b=${b_after}; want 3+3)"
        cleanup_ambient_pair; return
    fi

    cleanup_ambient_pair
    pass "${name}"
}

trap 'cleanup_release; cleanup_ambient_pair' EXIT

scenario_standalone_ambient                    || true
scenario_cluster_ambient                       || true
scenario_cluster_ambient_tls_auth              || true
scenario_ambient_authz_blocks_cross_release_meet || true

echo
log "Ambient scenario summary"
passed=0; failed=0
for r in "${RESULTS[@]}"; do
    printf '  %s\n' "${r}"
    [[ ${r} == PASS:* ]] && passed=$(( passed + 1 )) || failed=$(( failed + 1 ))
done
echo
log "Ambient: ${passed} passed, ${failed} failed"
(( failed == 0 ))
