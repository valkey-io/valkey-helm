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

# ---------------------------------------------------------------------------
# Scenario 5: the chart must refuse to install in ambient+cluster mode when
# AuthorizationPolicy is explicitly disabled — dropping it leaves the bus
# port with NO cross-release protection (the chart also skips the
# NetworkPolicy in ambient mode to avoid blocking HBONE). We proved live
# during review that this silently ships an open bus port; the fix is to
# fail closed at install time.
# ---------------------------------------------------------------------------
scenario_ambient_ap_disabled_refused() {
    local name="ambient: chart refuses install when authorizationPolicy.enabled=false + cluster"
    log "SCENARIO: ${name}"
    cleanup_release

    local out rc
    set +e
    out=$(hctl install "${RELEASE}" "${CHART_DIR}" \
            --set=istio.enabled=true \
            --set=istio.mode=ambient \
            --set=cluster.enabled=true \
            --set=cluster.shards=3 \
            --set=cluster.replicasPerShard=0 \
            --set=cluster.persistence.size=100Mi \
            --set=istio.authorizationPolicy.enabled=false \
            --dry-run 2>&1)
    rc=$?
    set -e

    if (( rc == 0 )); then
        fail "${name}" "dry-run succeeded but should have failed: ${out}"
        return
    fi
    if ! grep -q 'cluster-bus port unprotected' <<<"${out}"; then
        fail "${name}" "got error without the expected message (rc=${rc}): ${out}"
        return
    fi
    pass "${name}"
}

# ---------------------------------------------------------------------------
# Scenario 6: the chart must refuse to install when ambient + cluster +
# serviceAccount.create=false (with no explicit name), because every release
# collapses to the namespace's `default` SA and the AP can no longer
# distinguish between them. Live-repro'd in review: two releases merged
# despite both having the AP rendered. The fix is to fail closed at install
# time and force the user to pick a distinct SA name (or let the chart
# create one).
# ---------------------------------------------------------------------------
scenario_ambient_shared_default_sa_refused() {
    local name="ambient: chart refuses install when serviceAccount defaults to namespace-wide 'default'"
    log "SCENARIO: ${name}"
    cleanup_release

    local out rc
    set +e
    out=$(hctl install "${RELEASE}" "${CHART_DIR}" \
            --set=istio.enabled=true \
            --set=istio.mode=ambient \
            --set=cluster.enabled=true \
            --set=cluster.shards=3 \
            --set=cluster.replicasPerShard=0 \
            --set=cluster.persistence.size=100Mi \
            --set=serviceAccount.create=false \
            --dry-run 2>&1)
    rc=$?
    set -e

    if (( rc == 0 )); then
        fail "${name}" "dry-run succeeded but should have failed: ${out}"
        return
    fi
    if ! grep -q "serviceAccount.create=false AND serviceAccount.name empty" <<<"${out}"; then
        fail "${name}" "got error without the expected message (rc=${rc}): ${out}"
        return
    fi
    pass "${name}"
}

# ---------------------------------------------------------------------------
# Scenario 7: custom trustDomain must propagate into the AuthorizationPolicy
# principal. A cluster with `istio.trustDomain=my.mesh.example.com` whose AP
# still emits `cluster.local/…` would self-deny: same-release callers
# present an identity under the CUSTOM trust domain but the AP's ALLOW rule
# only matches the hardcoded one — the cluster-bus port defaults-denies
# even for its own pods and the cluster never forms.
# We install with the chart's default (cluster.local) but prove the RENDER
# honours the override. Testing the failure mode in-cluster would require
# reconfiguring Istio's trust domain, which isn't a chart-level concern.
# ---------------------------------------------------------------------------
scenario_ambient_trustdomain_override() {
    local name="ambient: AP principal follows istio.trustDomain override"
    log "SCENARIO: ${name}"
    cleanup_release

    if ! hctl install "${RELEASE}" "${CHART_DIR}" \
            --set=istio.enabled=true \
            --set=istio.mode=ambient \
            --set=cluster.enabled=true \
            --set=cluster.shards=3 \
            --set=cluster.replicasPerShard=0 \
            --set=cluster.persistence.size=100Mi \
            --set=istio.trustDomain=my.mesh.example.com \
            --wait --timeout=240s >/dev/null 2>&1; then
        # Install will NOT converge because Istio actually uses cluster.local —
        # that's a feature of this scenario. We only need the AP rendered to
        # verify the principal string.
        :
    fi

    local principals
    principals=$(kctl get authorizationpolicy "${RELEASE}-cluster-bus" \
        -o jsonpath='{.spec.rules[0].from[0].source.principals[*]}' 2>/dev/null)
    if [[ ${principals} != "my.mesh.example.com/ns/${NAMESPACE}/sa/${RELEASE}" ]]; then
        fail "${name}" "AP principals=${principals}, want my.mesh.example.com/ns/${NAMESPACE}/sa/${RELEASE}"
        return
    fi

    cleanup_release
    pass "${name}"
}

trap 'cleanup_release; cleanup_ambient_pair' EXIT

# ---------------------------------------------------------------------------
# Scenario 8: Prometheus scraping the metrics exporter must work in
# ambient mode. The AuthorizationPolicy is ALLOW-only, which triggers
# default-deny for any non-matching traffic — if the chart forgets to
# include the metrics port in the open rule, production Prometheus stacks
# silently stop seeing Valkey metrics the moment someone enables Istio.
# ---------------------------------------------------------------------------
scenario_ambient_prometheus_scrape() {
    local name="ambient: in-mesh Prometheus can scrape metrics exporter"
    log "SCENARIO: ${name}"
    cleanup_release

    if ! hctl install "${RELEASE}" "${CHART_DIR}" \
            --set=istio.enabled=true \
            --set=istio.mode=ambient \
            --set=cluster.enabled=true \
            --set=cluster.shards=3 \
            --set=cluster.replicasPerShard=0 \
            --set=cluster.persistence.size=100Mi \
            --set=metrics.enabled=true \
            --wait --timeout=300s >/dev/null; then
        fail "${name}" "helm install failed"; return
    fi
    kctl wait --for=condition=complete "job/${RELEASE}-cluster-init" --timeout=300s >/dev/null

    # Launch a curl pod enrolled in ambient (same mesh-participation shape
    # as an in-mesh Prometheus would have).
    local scraper="scrape-${RELEASE}-$$"
    kctl delete pod "${scraper}" --ignore-not-found --wait=true >/dev/null
    kctl run "${scraper}" \
        --image=curlimages/curl \
        --labels='istio.io/dataplane-mode=ambient' \
        --restart=Never \
        --command -- sleep 300 >/dev/null
    kctl wait --for=condition=Ready "pod/${scraper}" --timeout=120s >/dev/null

    local code out
    set +e
    out=$(kctl exec "${scraper}" -c "${scraper}" -- \
        curl -sS --max-time 10 -w '\nHTTP=%{http_code}\n' \
        "http://${RELEASE}-metrics.${NAMESPACE}.svc.cluster.local:9121/metrics" 2>&1)
    set -e
    code=$(awk -F= '/^HTTP=/{print $2}' <<<"${out}")

    kctl delete pod "${scraper}" --ignore-not-found --wait=false >/dev/null

    if [[ ${code} != "200" ]]; then
        fail "${name}" "scrape returned HTTP=${code:-<empty>}, body was: ${out}"
        return
    fi
    if ! grep -q '^redis_' <<<"${out}"; then
        fail "${name}" "HTTP 200 but body lacks redis_* metrics"
        return
    fi

    cleanup_release
    pass "${name}"
}

scenario_standalone_ambient                      || true
scenario_cluster_ambient                         || true
scenario_cluster_ambient_tls_auth                || true
scenario_ambient_authz_blocks_cross_release_meet || true
scenario_ambient_ap_disabled_refused             || true
scenario_ambient_shared_default_sa_refused       || true
scenario_ambient_trustdomain_override            || true
scenario_ambient_prometheus_scrape               || true

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
