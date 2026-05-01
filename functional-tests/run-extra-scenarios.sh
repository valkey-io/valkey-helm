#!/usr/bin/env bash
# Targeted regressions that don't fit the tls/auth/shard/rep/istio matrix.
# Each scenario is self-contained: install, assert, uninstall.

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "${HERE}/lib.sh"

RESULTS=()
pass() { RESULTS+=("PASS: $1"); }
fail() { RESULTS+=("FAIL: $1: $2"); return 1; }

cleanup_release() {
    hctl uninstall "${RELEASE}" 2>/dev/null || true
    kctl delete pvc --selector="app.kubernetes.io/instance=${RELEASE}" --ignore-not-found >/dev/null
}

# ---------------------------------------------------------------------------
# Scenario: auth.enabled=true with aclConfig only (no aclUsers) and metrics
# enabled. This used to CrashLoop the exporter with CreateContainerConfigError
# because the chart pointed REDIS_PASSWORD at a key `default-password` that
# only exists when there's an inline aclUsers.default.password. The fix is to
# only wire REDIS_PASSWORD when a real key exists.
# ---------------------------------------------------------------------------
scenario_aclconfig_metrics() {
    local name="aclConfig-only + metrics exporter must not crash"
    log "SCENARIO: ${name}"
    cleanup_release

    # Use an alternate release name to avoid colliding with the shared
    # fixture secret `valkey-auth` (managed by setup.sh, not Helm). The chart
    # generates `${release}-auth`, so a different release ⇒ a different secret.
    local release="${RELEASE}-aclcfg"
    hctl uninstall "${release}" 2>/dev/null || true
    kctl delete pvc --selector="app.kubernetes.io/instance=${release}" --ignore-not-found >/dev/null

    if ! hctl install "${release}" "${CHART_DIR}" \
            --set=metrics.enabled=true \
            --set=auth.enabled=true \
            --set-string="auth.aclConfig=user default on >simplepass ~* &* +@all" \
            --set-string='podLabels.sidecar\.istio\.io/inject=false' \
            --wait --timeout=180s >/dev/null; then
        fail "${name}" "helm install failed"
        hctl uninstall "${release}" 2>/dev/null || true
        return
    fi

    # Main container must be Running, metrics sidecar must be Ready. The bug
    # made the metrics container stick in CreateContainerConfigError forever —
    # no amount of probe-waiting would ever flip it to Ready.
    local pod
    pod=$(kctl get pod -l "app.kubernetes.io/instance=${release}" \
        -o jsonpath='{.items[0].metadata.name}')
    if ! kctl wait "pod/${pod}" \
            --for=condition=Ready --timeout=120s >/dev/null; then
        local status
        status=$(kctl get "pod/${pod}" -o jsonpath='{.status.containerStatuses[*].state}')
        fail "${name}" "pod never became Ready (state=${status})"
        hctl uninstall "${release}" 2>/dev/null || true
        return
    fi

    # Metrics endpoint actually responds. Use `kubectl port-forward` into a
    # local port — lets us hit the exporter from the host with curl, without
    # relying on either container having an HTTP client.
    local pf_port=19121 pf_pid
    kctl port-forward "pod/${pod}" "${pf_port}:9121" >/dev/null 2>&1 &
    pf_pid=$!
    # Give port-forward a moment to establish.
    for _ in $(seq 1 20); do
        if curl -sf --max-time 1 "http://127.0.0.1:${pf_port}/metrics" \
                >/dev/null 2>&1; then
            break
        fi
        sleep 0.5
    done

    local metrics_out
    metrics_out=$(curl -sf --max-time 5 "http://127.0.0.1:${pf_port}/metrics" \
        2>/dev/null || true)
    kill "${pf_pid}" 2>/dev/null || true
    wait "${pf_pid}" 2>/dev/null || true

    if ! grep -q 'redis_exporter_' <<<"${metrics_out}"; then
        fail "${name}" "/metrics did not serve redis_exporter_* counters"
        hctl uninstall "${release}" 2>/dev/null || true
        return
    fi

    hctl uninstall "${release}" 2>/dev/null || true
    kctl delete pvc --selector="app.kubernetes.io/instance=${release}" --ignore-not-found >/dev/null
    pass "${name}"
}

# ---------------------------------------------------------------------------
# Scenario: default-deny NetworkPolicy. Previously `networkPolicy.ingress: []`
# rendered an invalid policy (policyTypes: []), which the API accepts but is a
# no-op. The fix gates on hasKey, so an empty list still opts in.
# ---------------------------------------------------------------------------
scenario_default_deny_netpol() {
    local name="networkPolicy.ingress=[] produces a real default-deny policy"
    log "SCENARIO: ${name}"
    cleanup_release

    if ! hctl install "${RELEASE}" "${CHART_DIR}" \
            --set-string='podLabels.sidecar\.istio\.io/inject=false' \
            --set-json='networkPolicy={"ingress":[]}' \
            --wait --timeout=120s >/dev/null; then
        fail "${name}" "helm install failed"
        return
    fi

    # The original bug: `networkPolicy.ingress: []` rendered `policyTypes: []`,
    # which Kubernetes treats as "no policy in either direction" — silently
    # allowing all traffic despite the user clearly opting into default-deny.
    # The fix is to gate on hasKey, not truthiness.
    #
    # Checking via the API alone is fragile (kube-apiserver drops empty lists
    # on serialization), so:
    #   1) Assert policyTypes contains Ingress.
    #   2) Actually attempt a TCP connection from the testbench — a real
    #      default-deny policy blocks it; a no-op policy lets it through.
    local types
    types=$(kctl get networkpolicy "${RELEASE}" \
        -o jsonpath='{.spec.policyTypes[*]}')
    if [[ ${types} != *Ingress* ]]; then
        fail "${name}" "policyTypes=${types} (want to include Ingress)"
        return
    fi

    # Live traffic check. Use a short timeout — a default-deny policy drops
    # SYN packets, so the testbench will sit in CONNECT until the timeout.
    set +e
    testbench_exec_in "${TESTBENCH_POD}" sh -c \
        "timeout 5 valkey-cli -h valkey.${NAMESPACE}.svc.cluster.local ping" \
        >/dev/null 2>&1
    local rc=$?
    set -e
    if (( rc == 0 )); then
        fail "${name}" "ping succeeded — default-deny ingress policy is a no-op"
        return
    fi

    cleanup_release
    pass "${name}"
}

# ---------------------------------------------------------------------------
# Scenario: frontend Service must never expose the cluster bus port. The bus
# port is pod-to-pod gossip; routing it through a round-robin ClusterIP
# misdirects clients to arbitrary nodes.
# ---------------------------------------------------------------------------
scenario_bus_port_hidden() {
    local name="frontend service does not expose the cluster bus port"
    log "SCENARIO: ${name}"
    cleanup_release

    if ! hctl install "${RELEASE}" "${CHART_DIR}" \
            --set=cluster.enabled=true \
            --set=cluster.persistence.size=100Mi \
            --set=cluster.shards=3 \
            --set=cluster.replicasPerShard=0 \
            --set=cluster.busPort=16379 \
            --set-string='podLabels.sidecar\.istio\.io/inject=false' \
            --wait --timeout=300s >/dev/null; then
        fail "${name}" "helm install failed"
        return
    fi

    local frontend_ports headless_ports
    frontend_ports=$(kctl get service "${RELEASE}" \
        -o jsonpath='{.spec.ports[*].name}')
    headless_ports=$(kctl get service "${RELEASE}-headless" \
        -o jsonpath='{.spec.ports[*].name}')

    if grep -qw tcp-bus <<<"${frontend_ports}"; then
        fail "${name}" "frontend exposes tcp-bus (ports=${frontend_ports})"
        return
    fi
    if ! grep -qw tcp-bus <<<"${headless_ports}"; then
        fail "${name}" "headless missing tcp-bus (ports=${headless_ports})"
        return
    fi

    cleanup_release
    pass "${name}"
}

# ---------------------------------------------------------------------------
# Scenario: readiness probe must exist on the valkey container. Previously
# only startup+liveness were defined, so a pod that lost server health but
# kept the TCP socket would keep receiving traffic.
# ---------------------------------------------------------------------------
scenario_readiness_probe_exists() {
    local name="valkey container declares a readiness probe"
    log "SCENARIO: ${name}"
    cleanup_release

    if ! hctl install "${RELEASE}" "${CHART_DIR}" \
            --set-string='podLabels.sidecar\.istio\.io/inject=false' \
            --wait --timeout=120s >/dev/null; then
        fail "${name}" "helm install failed"
        return
    fi

    local probe
    probe=$(kctl get deployment "${RELEASE}" \
        -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.exec.command}')
    if [[ -z ${probe} ]]; then
        fail "${name}" "readinessProbe is missing"
        return
    fi
    # And it must be the NOAUTH-tolerant flavour.
    if ! grep -q 'NOAUTH' <<<"${probe}"; then
        fail "${name}" "readinessProbe does not tolerate NOAUTH (${probe})"
        return
    fi

    cleanup_release
    pass "${name}"
}

# ---------------------------------------------------------------------------
# Scenario: two independent Valkey clusters in the same namespace must stay
# independent. Valkey's CLUSTER MEET has no auth, so a MEET issued by (or
# forwarded through) a node in cluster A can merge cluster B into it. The
# chart's cluster-isolation NetworkPolicy pins the bus port to same-release
# pods; without it, a stray MEET wins.
#
# This test:
#   1) installs `valkey-a` and `valkey-b` in the same namespace, cluster mode;
#   2) issues CLUSTER MEET from a node in A targeting a node in B;
#   3) waits for gossip to propagate;
#   4) asserts A still has its original 3 nodes (not 6).
#
# Also runs a negative twin with `cluster.isolation.enabled=false` to prove
# the assertion has teeth — if isolation is the thing keeping them apart,
# disabling it must let the merge happen.
# ---------------------------------------------------------------------------

# Install one cluster-mode release with a given name and isolation flag.
# Globals it expects: NAMESPACE, CHART_DIR, KUBE_CONTEXT.
install_cluster() {
    local release=$1 isolation=$2
    hctl install "${release}" "${CHART_DIR}" \
        --set=cluster.enabled=true \
        --set=cluster.persistence.size=100Mi \
        --set=cluster.shards=3 \
        --set=cluster.replicasPerShard=0 \
        --set="cluster.isolation.enabled=${isolation}" \
        --set-string='podLabels.sidecar\.istio\.io/inject=false' \
        --wait --timeout=300s >/dev/null
}

# Count unique nodes reported by `cluster nodes` on pod-0 of the given release.
# Returns 0 if the query itself fails (counts as "indeterminate").
count_cluster_nodes() {
    local release=$1
    # Filter blanks + the "myself" marker to get the real node count.
    kctl exec "${release}-0" -c "${release}" -- sh -c \
        "valkey-cli cluster nodes 2>/dev/null | awk 'NF {print \$1}' | sort -u | wc -l" \
        2>/dev/null | tr -d '[:space:]' || echo 0
}

# Fire CLUSTER MEET from src_release pod-0 targeting dst_release pod-0.
poison_meet() {
    local src_release=$1 dst_release=$2
    local dst_ip
    dst_ip=$(kctl get pod "${dst_release}-0" -o jsonpath='{.status.podIP}')
    [[ -n ${dst_ip} ]] || return 1
    kctl exec "${src_release}-0" -c "${src_release}" -- \
        valkey-cli cluster meet "${dst_ip}" 6379 >/dev/null 2>&1 || true
}

cleanup_pair() {
    hctl uninstall valkey-iso-a 2>/dev/null || true
    hctl uninstall valkey-iso-b 2>/dev/null || true
    kctl delete pvc --selector='app.kubernetes.io/instance=valkey-iso-a' --ignore-not-found >/dev/null
    kctl delete pvc --selector='app.kubernetes.io/instance=valkey-iso-b' --ignore-not-found >/dev/null
}

scenario_two_clusters_isolated() {
    local name="two cluster-mode releases in one namespace stay isolated"
    log "SCENARIO: ${name}"
    cleanup_pair

    if ! install_cluster valkey-iso-a true; then
        fail "${name}" "install of valkey-iso-a failed"; cleanup_pair; return
    fi
    if ! install_cluster valkey-iso-b true; then
        fail "${name}" "install of valkey-iso-b failed"; cleanup_pair; return
    fi

    # Baseline — each cluster should see exactly 3 nodes (3 shards, 0 replicas).
    local a_before b_before
    a_before=$(count_cluster_nodes valkey-iso-a)
    b_before=$(count_cluster_nodes valkey-iso-b)
    if [[ ${a_before} != 3 || ${b_before} != 3 ]]; then
        fail "${name}" "baseline wrong (a=${a_before}, b=${b_before}; want 3+3)"
        cleanup_pair; return
    fi

    # Try to merge B into A.
    poison_meet valkey-iso-a valkey-iso-b

    # After a MEET, Valkey adds the peer to `cluster nodes` immediately as a
    # handshake placeholder — so a count of 4 for a few seconds is EXPECTED
    # whether or not the merge ultimately succeeds. The real signal is what
    # happens *after* the handshake timeout: if bus connectivity exists, the
    # node stays (count stays at 4+); if isolation blocks the bus, the
    # handshake fails and the placeholder is evicted (count returns to 3).
    #
    # Cluster node-timeout defaults to 15s; give the failure detector
    # multiple intervals to fire, then sample.
    sleep 45

    # After settling, the merge must NOT have stuck.
    local a_after b_after
    a_after=$(count_cluster_nodes valkey-iso-a)
    b_after=$(count_cluster_nodes valkey-iso-b)

    if [[ ${a_after} != 3 || ${b_after} != 3 ]]; then
        fail "${name}" "clusters merged (a=${a_after}, b=${b_after}; want 3+3 after settle)"
        cleanup_pair; return
    fi

    cleanup_pair
    pass "${name}"
}

# Negative twin: without isolation, the SAME MEET must succeed — otherwise
# the positive test isn't proving what we think it's proving.
scenario_isolation_off_lets_merge_happen() {
    local name="disabling isolation lets CLUSTER MEET actually merge (teeth check)"
    log "SCENARIO: ${name}"
    cleanup_pair

    if ! install_cluster valkey-iso-a false; then
        fail "${name}" "install of valkey-iso-a failed"; cleanup_pair; return
    fi
    if ! install_cluster valkey-iso-b false; then
        fail "${name}" "install of valkey-iso-b failed"; cleanup_pair; return
    fi

    poison_meet valkey-iso-a valkey-iso-b

    # Mirror the positive test's 45-second settle window: we're asking the
    # SAME question (has the handshake completed?) and need the same amount
    # of time for the node-timeout to fire.
    sleep 45

    local a_after
    a_after=$(count_cluster_nodes valkey-iso-a)
    if [[ ${a_after} -le 3 ]]; then
        fail "${name}" "MEET did not merge even without isolation (a=${a_after}); positive test cannot prove isolation works"
        cleanup_pair; return
    fi

    cleanup_pair
    pass "${name}"
}

trap 'cleanup_release; cleanup_pair' EXIT

scenario_aclconfig_metrics              || true
scenario_default_deny_netpol            || true
scenario_bus_port_hidden                || true
scenario_readiness_probe_exists         || true
scenario_two_clusters_isolated          || true
scenario_isolation_off_lets_merge_happen|| true

echo
log "Extra scenario summary"
passed=0; failed=0
for r in "${RESULTS[@]}"; do
    printf '  %s\n' "${r}"
    [[ ${r} == PASS:* ]] && passed=$(( passed + 1 )) || failed=$(( failed + 1 ))
done
echo
log "Extras: ${passed} passed, ${failed} failed"
(( failed == 0 ))
