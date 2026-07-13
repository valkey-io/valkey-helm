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

# ---------------------------------------------------------------------------
# Ambient-only regressions. Each of these tests a behaviour that's
# independent of the tls/auth/shard/rep dimensions, so it lives here
# rather than inflating the matrix with 16 copies of the same assertion.
# Each self-skips if the cluster lacks the ambient data plane.
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

# Cross-release CLUSTER MEET must be blocked by the ambient
# AuthorizationPolicy. Analogous to scenario_two_clusters_isolated above
# but driven at L4 via ztunnel rather than by NetworkPolicy (the
# NetworkPolicy is intentionally skipped in ambient — it would drop
# HBONE). The ONLY thing stopping the merge here is the AP, so we
# disable cluster.isolation.enabled to force that.
scenario_ambient_authz_blocks_cross_release_meet() {
    local name="ambient: AuthorizationPolicy blocks cross-release CLUSTER MEET"
    log "SCENARIO: ${name}"
    if ! istio_ambient_installed; then
        log "SKIP: ${name} (ztunnel not installed)"
        return
    fi
    cleanup_ambient_pair

    if ! install_ambient_cluster valkey-amb-a; then
        fail "${name}" "install of valkey-amb-a failed"; cleanup_ambient_pair; return
    fi
    if ! install_ambient_cluster valkey-amb-b; then
        fail "${name}" "install of valkey-amb-b failed"; cleanup_ambient_pair; return
    fi
    wait_for_cluster_init valkey-amb-a-cluster-init
    wait_for_cluster_init valkey-amb-b-cluster-init

    local a_before b_before
    a_before=$(count_cluster_nodes_ambient valkey-amb-a)
    b_before=$(count_cluster_nodes_ambient valkey-amb-b)
    if [[ ${a_before} != 3 || ${b_before} != 3 ]]; then
        fail "${name}" "baseline wrong (a=${a_before}, b=${b_before}; want 3+3)"
        cleanup_ambient_pair; return
    fi

    poison_meet_ambient valkey-amb-a valkey-amb-b

    # Same rationale as the sidecar-mode isolation test: after the MEET,
    # `cluster nodes` on A briefly shows 4 as a handshake placeholder.
    # The real signal is post-settle. Node-timeout defaults to 15s; give
    # it multiple intervals.
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

# The chart must refuse to install in ambient+cluster mode when the
# AuthorizationPolicy is explicitly disabled — dropping it leaves the bus
# port with NO cross-release protection (the NetworkPolicy is also
# skipped in ambient to avoid blocking HBONE). Fail-closed at template
# time so nobody silently ships an open cluster.
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

# The chart must refuse when ambient + cluster + serviceAccount.create=false
# with no explicit name, because every release collapses to the namespace's
# `default` SA and the AP can no longer distinguish releases. Repro'd live
# during review: two clusters merged despite both having the AP rendered.
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

# Custom trustDomain must propagate into the AuthorizationPolicy principal.
# A cluster with `istio.trustDomain=my.mesh.example.com` whose AP still
# emits `cluster.local/…` would self-deny: same-release callers present an
# identity under the CUSTOM trust domain but the AP's ALLOW rule only
# matches the hardcoded one, so the bus port default-denies even for its
# own pods.
# We don't actually reconfigure Istio's trust domain here — that's a
# cluster-wide concern, not chart-level — so the install does NOT fully
# converge. The test inspects the rendered AP to confirm the principal
# string follows the override. That's the piece the chart owns.
scenario_ambient_trustdomain_override() {
    local name="ambient: AP principal follows istio.trustDomain override"
    log "SCENARIO: ${name}"
    if ! istio_ambient_installed; then
        log "SKIP: ${name} (ztunnel not installed)"
        return
    fi
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
        # Expected: install won't converge because the actual mesh trust
        # domain is still cluster.local. We only need the AP rendered to
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

# Prometheus scraping the metrics exporter must work in ambient mode. The
# AuthorizationPolicy is ALLOW-only, which triggers Istio default-deny for
# any non-matching traffic — if the chart forgets to include the metrics
# port in the open rule, production Prometheus stacks silently stop
# seeing Valkey metrics the moment someone enables Istio.
scenario_ambient_prometheus_scrape() {
    local name="ambient: in-mesh Prometheus can scrape metrics exporter"
    log "SCENARIO: ${name}"
    if ! istio_ambient_installed; then
        log "SKIP: ${name} (ztunnel not installed)"
        return
    fi
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
    wait_for_cluster_init

    # An ambient-enrolled curl pod simulates an in-mesh Prometheus.
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

# ---------------------------------------------------------------------------
# Scenario: `kubectl rollout restart` on a replicated cluster must not cause
# client-visible disruption. The preStop hook runs `CLUSTER FAILOVER` on
# every primary before SIGTERM, so the shard already has a new primary by
# the time the old pod terminates. We assert this by:
#
#   1) Installing cluster.shards=3, cluster.replicasPerShard=1 (6 pods).
#   2) Recording each pod's role (master/slave) — this is our baseline.
#   3) Writing a known key through any pod (cluster redirects handle placement).
#   4) `kubectl rollout restart` the STS and waiting for the rollout.
#   5) Re-checking cluster_state, master/slave counts, and the key's value.
#   6) Comparing new roles to baseline: since every primary is asked to hand
#      off to its own replica, every primary/replica pair should have flipped
#      ordinals. We assert AT LEAST ONE pod's role changed — any weaker check
#      would pass even if the hook never ran and the cluster simply waited
#      through node-timeout failovers.
#
# If the preStop hook is broken or absent, steps 5-6 still "work" in the sense
# that the cluster eventually self-heals via node-timeout, but:
#   - there's a 15s+ window of unavailability per primary,
#   - and the pod role stays the same after restart (the restarted pod
#     re-joins as primary because its nodes.conf persisted), so the role-flip
#     assertion catches it.
#
# ISOLATION — shutdownOnSigterm="" is set deliberately. The chart now defaults
# cluster.shutdownOnSigterm=failover, which produces the SAME role flips on
# SIGTERM. If we left it on, a completely broken preStop hook would still make
# this test pass (shutdown-on-sigterm would do the handover instead), so the
# role-flip assertion would no longer have teeth against a preStop regression.
# Disabling the native layer here scopes the signal to preStop ALONE — mirror
# image of scenario_shutdown_on_sigterm_failover, which disables preStop to
# scope its signal to shutdown-on-sigterm alone. Their coexistence at defaults
# is covered separately by scenario_failover_layers_coexist.
# ---------------------------------------------------------------------------
scenario_rollout_restart_orderly_failover() {
    local name="rollout restart performs orderly CLUSTER FAILOVER (no client-visible gap)"
    log "SCENARIO: ${name}"
    cleanup_release

    # nodeTimeout pinned high (3 min) so cluster-node-timeout auto-failover
    # CANNOT fire during the rollout — a normal per-pod restart takes ~10-30s
    # and the whole rollout ~2-3min, so with a 15s default timeout the
    # observed role-flip signal could be produced either by preStop OR by
    # auto-failover of an in-flight primary. Bumping to 180s guarantees any
    # observed flip is the work of preStop (shutdown-on-sigterm disabled below).
    if ! hctl install "${RELEASE}" "${CHART_DIR}" \
            --set=cluster.enabled=true \
            --set=cluster.persistence.size=100Mi \
            --set=cluster.shards=3 \
            --set=cluster.replicasPerShard=1 \
            --set=cluster.nodeTimeout=180000 \
            --set-string=cluster.shutdownOnSigterm= \
            --wait --timeout=300s >/dev/null; then
        fail "${name}" "helm install failed"
        return
    fi
    wait_for_cluster_init

    # Gossip convergence lags job completion: the init Job returns "done"
    # once `cluster create` is ACK'd, but `cluster_state:ok` requires every
    # node to have seen every other node's PING/PONG. Writing canary data
    # or triggering a rollout before that window closes lets the preStop
    # script's own `cluster_state != ok` early-exit fire, bypassing the
    # graceful FAILOVER and silently dropping in-memory writes when the
    # primary pod is replaced.
    local s
    for _ in $(seq 1 60); do
        s=$(kctl exec "${RELEASE}-0" -c "${RELEASE}" -- \
            valkey-cli cluster info 2>/dev/null \
            | awk -F: '/^cluster_state:/{print $2}' | tr -d '\r\n' || true)
        [[ ${s} == ok ]] && break
        sleep 2
    done
    if [[ ${s} != ok ]]; then
        fail "${name}" "cluster_state=${s:-<unavailable>} after install (want ok before rollout)"
        cleanup_release; return
    fi

    # Capture the role of every pod pre-restart. Keyed by pod ordinal so we
    # can compare "same ordinal, different role" after.
    snapshot_roles() {
        local n=6 i role
        for i in $(seq 0 $((n - 1))); do
            role=$(kctl exec "${RELEASE}-${i}" -c "${RELEASE}" -- \
                valkey-cli info replication 2>/dev/null \
                | awk -F: '/^role:/{print $2}' | tr -d '\r\n' || true)
            printf '%s=%s\n' "${i}" "${role}"
        done
    }

    local before
    before=$(snapshot_roles)
    local masters_before slaves_before
    masters_before=$(printf '%s\n' "${before}" | grep -c '=master' || true)
    slaves_before=$(printf '%s\n' "${before}" | grep -c '=slave\|=replica' || true)
    if [[ ${masters_before} != 3 || ${slaves_before} != 3 ]]; then
        fail "${name}" "baseline wrong: masters=${masters_before} slaves=${slaves_before} (want 3+3)"
        cleanup_release; return
    fi

    # Write a canary key so we can prove data integrity after the rollout.
    # Must write through a CLUSTER-aware client so slot routing works —
    # valkey-cli -c follows MOVED redirects. The value contains shell
    # metacharacters for the same reason AUTH_PASSWORD does.
    local canary_key="prestop-canary-$$"
    local canary_val='rollout-ok $shell "quote" \back`tick`'
    if ! kctl exec "${RELEASE}-0" -c "${RELEASE}" -- \
            valkey-cli -c set "${canary_key}" "${canary_val}" >/dev/null 2>&1; then
        fail "${name}" "initial SET failed"
        cleanup_release; return
    fi

    # The actual rollout. Default updateStrategy=RollingUpdate → pods
    # restart one at a time from highest ordinal (podManagementPolicy
    # controls creation/deletion parallelism, not rolling-update pacing).
    # Each primary-pod restart should trigger a preStop FAILOVER; each
    # replica-pod restart should no-op.
    log "triggering rollout restart"
    kctl rollout restart "statefulset/${RELEASE}" >/dev/null

    # Rollout must complete within terminationGracePeriodSeconds * 6 + a
    # little slack — each pod can take up to the grace period in the
    # worst case (preStop timeout + SIGTERM flush).
    if ! kctl rollout status "statefulset/${RELEASE}" --timeout=600s >/dev/null; then
        fail "${name}" "rollout status never converged"
        cleanup_release; return
    fi

    # Give gossip a moment to settle post-rollout — cluster_state flips to
    # :ok only after every node sees every other node, and the last pod to
    # restart may still be converging when rollout status returns.
    local state
    for _ in $(seq 1 30); do
        state=$(kctl exec "${RELEASE}-0" -c "${RELEASE}" -- \
            valkey-cli cluster info 2>/dev/null \
            | awk -F: '/^cluster_state:/{print $2}' | tr -d '\r\n' || true)
        [[ ${state} == ok ]] && break
        sleep 2
    done
    if [[ ${state} != ok ]]; then
        fail "${name}" "cluster_state=${state:-<unavailable>} after rollout (want ok)"
        cleanup_release; return
    fi

    # Still 3 masters / 3 slaves — i.e. the handovers completed and every
    # shard has the right shape.
    local after masters_after slaves_after
    after=$(snapshot_roles)
    masters_after=$(printf '%s\n' "${after}" | grep -c '=master' || true)
    slaves_after=$(printf '%s\n' "${after}" | grep -c '=slave\|=replica' || true)
    if [[ ${masters_after} != 3 || ${slaves_after} != 3 ]]; then
        fail "${name}" "post-rollout shape wrong: masters=${masters_after} slaves=${slaves_after} (want 3+3)"
        cleanup_release; return
    fi

    # Canary key survives (via MOVED redirect if the slot moved to a
    # different primary).
    local got
    got=$(kctl exec "${RELEASE}-0" -c "${RELEASE}" -- \
        valkey-cli -c get "${canary_key}" 2>/dev/null || true)
    if [[ ${got} != "${canary_val}" ]]; then
        fail "${name}" "canary key lost: got='${got}' want='${canary_val}'"
        cleanup_release; return
    fi

    # Expect every primary's ordinal to flip: the rollout restarts each pod
    # once, each primary-pod restart's preStop hands off to a replica, and
    # the ex-primary returns as replica. So of the 3 original primaries,
    # all 3 should now be replicas on those ordinals ⇒ at least 3 flips.
    # With nodeTimeout pinned high above, no other mechanism can produce
    # flips during the rollout window, so this is a precise signal.
    # A broken / missing preStop yields 0 flips (every pod persists its
    # role in nodes.conf and rejoins as that role).
    local flips=0 line ordinal role_before role_after
    for line in ${before}; do
        ordinal=${line%=*}
        role_before=${line#*=}
        role_after=$(printf '%s\n' "${after}" | awk -F= -v o="${ordinal}" '$1 == o {print $2}')
        if [[ ${role_before} != "${role_after}" ]]; then
            flips=$(( flips + 1 ))
        fi
    done
    if (( flips < 3 )); then
        fail "${name}" "only ${flips}/6 ordinals flipped — expected >=3 (every primary's preStop should hand off to a replica). before='${before}' after='${after}'"
        cleanup_release; return
    fi
    log "roles flipped on ${flips}/6 pods — handover ran"

    cleanup_release
    pass "${name}"
}

# ---------------------------------------------------------------------------
# Scenario: the NATIVE shutdown-on-sigterm=failover directive hands a primary's
# slots to a replica on SIGTERM, WITHOUT the preStop hook.
#
# What shutdown-on-sigterm does — and does NOT do:
#   It is a SIGTERM handler inside valkey-server: on SIGTERM it hands the
#   primary's slots to an up-to-date replica before exiting. It covers the
#   GRACEFUL termination path only — rollout restart, eviction, drain,
#   `kubectl delete pod` with a normal grace period. It does NOT guard against
#   an UNGRACEFUL kill: a force-delete (--grace-period=0) collapses the grace
#   window so the handler can't finish, and an OOM kill / node crash / power
#   loss deliver SIGKILL or no signal at all — nothing an in-process handler
#   can catch. That path is covered by Valkey's own cluster-node-timeout
#   auto-failover, a different mechanism this scenario does not exercise.
#
# Why a separate scenario from rollout_restart_orderly_failover:
#   That test proves the preStop CLUSTER FAILOVER hook works. This one proves
#   the second, independent defence layer — the server-side
#   `shutdown-on-sigterm failover` line in valkey.conf — works ON ITS OWN.
#   Both act on the SAME graceful SIGTERM path; shutdown-on-sigterm is the
#   native backstop that still fires when the preStop hook cannot — when
#   preStopFailover is disabled, its ConfigMap is not mounted, or its
#   best-effort script hits an error path and exits without handing off.
#
# Isolation, so a pass can ONLY be attributed to shutdown-on-sigterm:
#   * preStopFailover.enabled=false — the hook (and its cluster-script mount)
#     is not even rendered, so it cannot be the cause of any handover.
#   * nodeTimeout=180000 — cluster-node-timeout auto-failover CANNOT fire in
#     the few seconds a single graceful pod delete takes, so an observed
#     role flip is not the cluster promoting a replica after declaring the
#     primary dead. The only remaining mechanism is the primary handing off
#     as it processes SIGTERM.
#
# We delete ONE primary pod with the DEFAULT grace period (a normal graceful
# SIGTERM — NOT --force, which would also bypass shutdown-on-sigterm by
# SIGKILLing). A cluster-aware canary written before the delete must survive,
# and the ex-primary must come back demoted to replica (proof it handed off
# rather than being killed and restarted still-primary).
# ---------------------------------------------------------------------------
scenario_shutdown_on_sigterm_failover() {
    local name="native shutdown-on-sigterm=failover hands off primary without preStop hook"
    log "SCENARIO: ${name}"
    cleanup_release

    if ! hctl install "${RELEASE}" "${CHART_DIR}" \
            --set=cluster.enabled=true \
            --set=cluster.persistence.size=100Mi \
            --set=cluster.shards=3 \
            --set=cluster.replicasPerShard=1 \
            --set=cluster.preStopFailover.enabled=false \
            --set=cluster.nodeTimeout=180000 \
            --wait --timeout=300s >/dev/null; then
        fail "${name}" "helm install failed"
        return
    fi
    wait_for_cluster_init

    # Isolation assertion #1: the preStop hook must NOT be rendered. If it is,
    # a handover below could be the hook's doing, not shutdown-on-sigterm's,
    # and the whole scenario would be measuring the wrong thing.
    local lifecycle
    lifecycle=$(kctl get statefulset "${RELEASE}" \
        -o jsonpath='{.spec.template.spec.containers[0].lifecycle}')
    if [[ -n ${lifecycle} ]]; then
        fail "${name}" "preStop lifecycle unexpectedly rendered (want none): ${lifecycle}"
        cleanup_release; return
    fi

    # Isolation assertion #2: the directive is actually live on the server.
    local sos
    sos=$(kctl exec "${RELEASE}-0" -c "${RELEASE}" -- \
        valkey-cli config get shutdown-on-sigterm 2>/dev/null \
        | tr -d '\r' | awk 'NR==2{print}')
    if [[ ${sos} != failover ]]; then
        fail "${name}" "shutdown-on-sigterm=${sos:-<unset>} on server, want 'failover'"
        cleanup_release; return
    fi

    # Wait for gossip convergence before writing the canary (same rationale as
    # the rollout scenario: a premature write can land on a node that hasn't
    # yet seen the full topology).
    local s
    for _ in $(seq 1 60); do
        s=$(kctl exec "${RELEASE}-0" -c "${RELEASE}" -- \
            valkey-cli cluster info 2>/dev/null \
            | awk -F: '/^cluster_state:/{print $2}' | tr -d '\r\n' || true)
        [[ ${s} == ok ]] && break
        sleep 2
    done
    if [[ ${s} != ok ]]; then
        fail "${name}" "cluster_state=${s:-<unavailable>} after install (want ok)"
        cleanup_release; return
    fi

    # Find a pod that is currently a primary; capture the whole role vector so
    # we can prove this specific ordinal flipped afterwards.
    role_of() {
        kctl exec "${RELEASE}-$1" -c "${RELEASE}" -- \
            valkey-cli info replication 2>/dev/null \
            | awk -F: '/^role:/{print $2}' | tr -d '\r\n' || true
    }
    local prim="" i
    for i in 0 1 2 3 4 5; do
        if [[ $(role_of "${i}") == master ]]; then prim=${i}; break; fi
    done
    if [[ -z ${prim} ]]; then
        fail "${name}" "no primary pod found before delete"
        cleanup_release; return
    fi

    # Cluster-aware canary (follows MOVED). Shell metacharacters for the same
    # quoting-coverage reason as elsewhere.
    local canary_key="sos-canary-$$"
    local canary_val='native-shutdown-ok $x "q" \b`t`'
    if ! kctl exec "${RELEASE}-0" -c "${RELEASE}" -- \
            valkey-cli -c set "${canary_key}" "${canary_val}" >/dev/null 2>&1; then
        fail "${name}" "initial SET failed"
        cleanup_release; return
    fi

    # Graceful delete of the chosen primary — DEFAULT grace period, so kubelet
    # sends SIGTERM and valkey-server runs its shutdown-on-sigterm handler.
    # This is deliberate: shutdown-on-sigterm ONLY acts on the graceful path.
    # --force/--grace-period=0 would collapse the grace window and SIGKILL the
    # process, bypassing the very handler under test (that ungraceful path is
    # cluster-node-timeout's job, not this feature's). --wait=false so we can
    # watch the handover live.
    log "gracefully deleting primary pod ${RELEASE}-${prim} (SIGTERM path)"
    kctl delete pod "${RELEASE}-${prim}" --wait=false >/dev/null

    # The shard must acquire a new primary FAST — well inside the 180s
    # node-timeout, which is the whole point: this is the handoff, not
    # auto-failover. Observe from a pod we did NOT delete.
    local observer=$(( (prim + 1) % 6 ))
    local state masters
    for _ in $(seq 1 20); do
        state=$(kctl exec "${RELEASE}-${observer}" -c "${RELEASE}" -- \
            valkey-cli cluster info 2>/dev/null \
            | awk -F: '/^cluster_state:/{print $2}' | tr -d '\r\n' || true)
        masters=$(kctl exec "${RELEASE}-${observer}" -c "${RELEASE}" -- \
            valkey-cli cluster nodes 2>/dev/null | grep -c master || true)
        [[ ${state} == ok && ${masters} == 3 ]] && break
        sleep 3
    done
    if [[ ${state} != ok || ${masters} != 3 ]]; then
        fail "${name}" "shard did not re-form: cluster_state=${state:-<unavailable>} masters=${masters} (want ok/3)"
        cleanup_release; return
    fi

    # Ex-primary must come back demoted to replica. If shutdown-on-sigterm had
    # NOT handed off, the pod would persist role=master in nodes.conf and
    # rejoin still claiming the slots — so this is the load-bearing assertion.
    if ! kctl wait --for=condition=Ready "pod/${RELEASE}-${prim}" --timeout=120s >/dev/null 2>&1; then
        fail "${name}" "ex-primary ${RELEASE}-${prim} never became Ready again"
        cleanup_release; return
    fi
    local after_role=""
    for _ in $(seq 1 15); do
        after_role=$(role_of "${prim}")
        [[ ${after_role} == slave || ${after_role} == replica ]] && break
        sleep 2
    done
    if [[ ${after_role} != slave && ${after_role} != replica ]]; then
        fail "${name}" "ex-primary ${RELEASE}-${prim} role=${after_role:-<unknown>} after restart — expected demotion to replica (handoff did not happen)"
        cleanup_release; return
    fi

    # Canary survives the handoff (via MOVED if the slot moved primaries).
    local got
    got=$(kctl exec "${RELEASE}-${observer}" -c "${RELEASE}" -- \
        valkey-cli -c get "${canary_key}" 2>/dev/null || true)
    if [[ ${got} != "${canary_val}" ]]; then
        fail "${name}" "canary lost across handoff: got='${got}' want='${canary_val}'"
        cleanup_release; return
    fi
    log "ex-primary ${RELEASE}-${prim} demoted to ${after_role}; canary intact — native handoff confirmed"

    cleanup_release
    pass "${name}"
}

# ---------------------------------------------------------------------------
# Scenario: preStopFailover and shutdown-on-sigterm must COEXIST with no
# adverse interaction — the real production default (both enabled).
#
# The two layers act on the same graceful-termination path, in sequence:
#   1. kubelet runs the preStop hook FIRST, blocking SIGTERM. On a primary it
#      drives CLUSTER FAILOVER from a replica and polls until it observes
#      ITSELF demoted to replica, then exits.
#   2. kubelet then sends SIGTERM. shutdown-on-sigterm=failover fires, but the
#      pod is ALREADY a replica by then, so its handover is a no-op and it
#      exits cleanly.
# They are sequential, not concurrent, and the second is designed to no-op
# after the first. The failure modes this guards against are what "adverse
# interaction" would actually look like:
#   * double promotion / split-brain — more than one primary claiming a
#     shard's slots ⇒ masters != 3 after the rollout;
#   * a fight between the two handoffs leaving the cluster wedged ⇒
#     cluster_state != ok, or the rollout never converging;
#   * either handover dropping an in-flight write ⇒ canary lost.
# So this is the two isolation tests' counterpart: they each prove ONE layer
# works alone; this proves turning BOTH on (the shipped default) is safe.
#
# Unlike scenario_rollout_restart_orderly_failover, this does NOT pin a high
# nodeTimeout or count role flips — it isn't attributing the handover to a
# specific layer, it's asserting the end state is healthy no matter which
# layer(s) acted. Everything runs at chart defaults on purpose.
# ---------------------------------------------------------------------------
scenario_failover_layers_coexist() {
    local name="preStopFailover + shutdown-on-sigterm coexist without adverse interaction"
    log "SCENARIO: ${name}"
    cleanup_release

    # Both layers at their DEFAULTS: preStopFailover.enabled=true and
    # shutdownOnSigterm=failover. This is exactly what a user gets out of the
    # box — no failover-related overrides at all.
    if ! hctl install "${RELEASE}" "${CHART_DIR}" \
            --set=cluster.enabled=true \
            --set=cluster.persistence.size=100Mi \
            --set=cluster.shards=3 \
            --set=cluster.replicasPerShard=1 \
            --wait --timeout=300s >/dev/null; then
        fail "${name}" "helm install failed"
        return
    fi
    wait_for_cluster_init

    # Confirm BOTH layers are actually in effect — otherwise this degenerates
    # into a duplicate of one of the single-layer tests without anyone noticing.
    local lifecycle sos
    lifecycle=$(kctl get statefulset "${RELEASE}" \
        -o jsonpath='{.spec.template.spec.containers[0].lifecycle.preStop.exec.command}')
    if [[ ${lifecycle} != *prestop.sh* ]]; then
        fail "${name}" "preStop hook not rendered (${lifecycle:-<none>}) — cannot test coexistence"
        cleanup_release; return
    fi
    sos=$(kctl exec "${RELEASE}-0" -c "${RELEASE}" -- \
        valkey-cli config get shutdown-on-sigterm 2>/dev/null \
        | tr -d '\r' | awk 'NR==2{print}')
    if [[ ${sos} != failover ]]; then
        fail "${name}" "shutdown-on-sigterm=${sos:-<unset>} (want failover) — cannot test coexistence"
        cleanup_release; return
    fi

    # Wait for gossip convergence before writing the canary.
    local s
    for _ in $(seq 1 60); do
        s=$(kctl exec "${RELEASE}-0" -c "${RELEASE}" -- \
            valkey-cli cluster info 2>/dev/null \
            | awk -F: '/^cluster_state:/{print $2}' | tr -d '\r\n' || true)
        [[ ${s} == ok ]] && break
        sleep 2
    done
    if [[ ${s} != ok ]]; then
        fail "${name}" "cluster_state=${s:-<unavailable>} after install (want ok)"
        cleanup_release; return
    fi

    # Baseline shape: 3 masters + 3 slaves.
    local masters_before slaves_before i role
    masters_before=0; slaves_before=0
    for i in 0 1 2 3 4 5; do
        role=$(kctl exec "${RELEASE}-${i}" -c "${RELEASE}" -- \
            valkey-cli info replication 2>/dev/null \
            | awk -F: '/^role:/{print $2}' | tr -d '\r\n' || true)
        case "${role}" in
            master) masters_before=$(( masters_before + 1 )) ;;
            slave|replica) slaves_before=$(( slaves_before + 1 )) ;;
        esac
    done
    if [[ ${masters_before} != 3 || ${slaves_before} != 3 ]]; then
        fail "${name}" "baseline wrong: masters=${masters_before} slaves=${slaves_before} (want 3+3)"
        cleanup_release; return
    fi

    # Canary through a cluster-aware client (follows MOVED). Shell
    # metacharacters for the usual quoting-coverage reason.
    local canary_key="coexist-canary-$$"
    local canary_val='both-layers-ok $x "q" \b`t`'
    if ! kctl exec "${RELEASE}-0" -c "${RELEASE}" -- \
            valkey-cli -c set "${canary_key}" "${canary_val}" >/dev/null 2>&1; then
        fail "${name}" "initial SET failed"
        cleanup_release; return
    fi

    # Full rollout with BOTH layers live. Every primary pod's shutdown fires
    # preStop (blocking SIGTERM) THEN shutdown-on-sigterm — the exact sequence
    # where a mishandled interaction would show up.
    log "triggering rollout restart with both failover layers enabled"
    kctl rollout restart "statefulset/${RELEASE}" >/dev/null
    if ! kctl rollout status "statefulset/${RELEASE}" --timeout=600s >/dev/null; then
        fail "${name}" "rollout never converged — possible deadlock between the two layers"
        cleanup_release; return
    fi

    # Post-rollout must re-converge to a HEALTHY, correctly-shaped cluster.
    local state
    for _ in $(seq 1 30); do
        state=$(kctl exec "${RELEASE}-0" -c "${RELEASE}" -- \
            valkey-cli cluster info 2>/dev/null \
            | awk -F: '/^cluster_state:/{print $2}' | tr -d '\r\n' || true)
        [[ ${state} == ok ]] && break
        sleep 2
    done
    if [[ ${state} != ok ]]; then
        fail "${name}" "cluster_state=${state:-<unavailable>} after rollout (want ok)"
        cleanup_release; return
    fi

    # The load-bearing anti-split-brain assertion: EXACTLY 3 masters and 3
    # slaves. Double promotion (both layers each promoting a different replica
    # for the same shard) would surface as masters>3 or a slot owned twice.
    local masters_after slaves_after
    masters_after=0; slaves_after=0
    for i in 0 1 2 3 4 5; do
        role=$(kctl exec "${RELEASE}-${i}" -c "${RELEASE}" -- \
            valkey-cli info replication 2>/dev/null \
            | awk -F: '/^role:/{print $2}' | tr -d '\r\n' || true)
        case "${role}" in
            master) masters_after=$(( masters_after + 1 )) ;;
            slave|replica) slaves_after=$(( slaves_after + 1 )) ;;
        esac
    done
    if [[ ${masters_after} != 3 || ${slaves_after} != 3 ]]; then
        fail "${name}" "post-rollout shape wrong: masters=${masters_after} slaves=${slaves_after} (want 3+3 — >3 masters would indicate double-promotion/split-brain)"
        cleanup_release; return
    fi

    # Every slot must be covered exactly once — a subtler split-brain check
    # than the role count (catches a slot claimed by two primaries).
    local slots_ok
    slots_ok=$(kctl exec "${RELEASE}-0" -c "${RELEASE}" -- \
        valkey-cli cluster info 2>/dev/null \
        | awk -F: '/^cluster_slots_ok:/{print $2}' | tr -d '\r\n' || true)
    if [[ ${slots_ok} != 16384 ]]; then
        fail "${name}" "cluster_slots_ok=${slots_ok:-<unavailable>} after rollout (want 16384)"
        cleanup_release; return
    fi

    # Canary survives the double-layered handover.
    local got
    got=$(kctl exec "${RELEASE}-0" -c "${RELEASE}" -- \
        valkey-cli -c get "${canary_key}" 2>/dev/null || true)
    if [[ ${got} != "${canary_val}" ]]; then
        fail "${name}" "canary lost with both layers enabled: got='${got}' want='${canary_val}'"
        cleanup_release; return
    fi
    log "both layers enabled: cluster ok, 3+3 shape, all slots covered, canary intact"

    cleanup_release
    pass "${name}"
}

# ---------------------------------------------------------------------------
# Scenario: cluster bus dials by IP, even with cluster-preferred-endpoint-type
# =hostname. After a rolling restart, a pod whose nodes.conf has only stale
# peer IPs becomes a stranded minority partition — every gossip attempt
# times out against dead IPs and it never gets the chance to learn fresh
# ones. The chart's init container re-resolves each peer's announced FQDN
# and rewrites stale IPs in /data/nodes.conf before valkey-server starts;
# this scenario proves that refresh works end-to-end.
#
# Reproduction:
#   1) Install cluster (replicasPerShard=1) and wait for cluster_state:ok.
#   2) Snapshot pod-0's nodes.conf to extract the real peer IPs.
#   3) Poison: replace every peer IP in pod-0's nodes.conf with TEST-NET-1
#      (192.0.2.0/24, RFC 5737 documentation range — guaranteed unroutable).
#   4) SIGKILL valkey-server (pid 1) so the shutdown handler can't rewrite
#      nodes.conf back to good state; the pod restarts via the StatefulSet
#      controller.
#   5) Wait for pod-0 to be Ready again. The init container's refresh
#      block should re-resolve every peer FQDN and rewrite the IPs back
#      to the real ones BEFORE valkey-server starts.
#   6) Assert: pod-0's nodes.conf no longer contains 192.0.2.99 and
#      cluster_state from pod-0's perspective is back to ok.
#
# Without the refresh: pod-0 boots, dials 192.0.2.99 on the bus, every
# connection times out, cluster_state stays fail forever. So the
# assertion has teeth — a regression that drops the refresh would leave
# the poisoned IPs in place and cluster_state would never recover.
# ---------------------------------------------------------------------------
scenario_nodes_conf_ip_refresh() {
    local name="cluster init refreshes stale nodes.conf IPs after pod restart"
    log "SCENARIO: ${name}"
    cleanup_release

    if ! hctl install "${RELEASE}" "${CHART_DIR}" \
            --set=cluster.enabled=true \
            --set=cluster.persistence.size=100Mi \
            --set=cluster.shards=3 \
            --set=cluster.replicasPerShard=1 \
            --wait --timeout=300s >/dev/null; then
        fail "${name}" "helm install failed"
        return
    fi
    wait_for_cluster_init

    # Wait for gossip convergence — same rationale as the rollout
    # scenario: the init Job returning doesn't mean every node has seen
    # every PING/PONG yet, and we need cluster_state:ok before we can
    # meaningfully assert it recovers.
    local s
    for _ in $(seq 1 60); do
        s=$(kctl exec "${RELEASE}-0" -c "${RELEASE}" -- \
            valkey-cli cluster info 2>/dev/null \
            | awk -F: '/^cluster_state:/{print $2}' | tr -d '\r\n' || true)
        [[ ${s} == ok ]] && break
        sleep 2
    done
    if [[ ${s} != ok ]]; then
        fail "${name}" "cluster_state=${s:-<unavailable>} after install (need ok before poisoning)"
        cleanup_release; return
    fi

    # Snapshot the original nodes.conf for diagnostics and to confirm
    # poisoning actually changes content.
    local orig
    orig=$(kctl exec "${RELEASE}-0" -c "${RELEASE}" -- cat /data/nodes.conf 2>/dev/null)
    if [[ -z ${orig} ]]; then
        fail "${name}" "failed to read /data/nodes.conf on ${RELEASE}-0"
        cleanup_release; return
    fi

    # Poison: replace every peer's IP token with 192.0.2.99 (RFC 5737
    # documentation prefix — guaranteed unroutable). Critically, SIGSTOP
    # valkey-server BEFORE rewriting nodes.conf — otherwise the live
    # server's gossip tick (every cluster-node-timeout/2 ≈ 7.5 s) or any
    # incoming gossip event from a peer would rewrite nodes.conf back to
    # the real IPs, defeating the test. SIGSTOP freezes the process so
    # it can't write the file; the subsequent force-delete sends SIGKILL
    # which clears the STOP and tears the container down.
    #
    # Atomic file swap (write+mv) so a kill mid-write can't corrupt
    # anything; sync forces the page cache to disk so the new pod's
    # init container reads the poison from the PVC.
    log "SIGSTOPping valkey-server and poisoning /data/nodes.conf on ${RELEASE}-0"
    # shellcheck disable=SC2016
    if ! kctl exec "${RELEASE}-0" -c "${RELEASE}" -- sh -c '
            kill -STOP 1 \
            && awk '"'"'
              # Pass through blank lines and the "vars currentEpoch ..." footer.
              /^$/ || /^vars / { print; next }
              # Field 2 is "<ip:port@busport>,<fqdn>,..." — replace ONLY
              # the leading ip:port@busport, keep everything else. The
              # production bug had myself stale too, so we deliberately
              # poison the myself line: the refresh block must handle it.
              {
                # Split field 2 on commas: head is ip:port@busport, tail is rest.
                n = split($2, a, ",")
                head = a[1]
                tail = ""
                for (i = 2; i <= n; i++) tail = tail "," a[i]
                # Replace the IP only; preserve port and bus port.
                sub(/^[0-9.]+/, "192.0.2.99", head)
                $2 = head tail
                print
              }
            '"'"' /data/nodes.conf >/data/nodes.conf.poisoned \
            && mv /data/nodes.conf.poisoned /data/nodes.conf \
            && sync
        '; then
        fail "${name}" "failed to poison /data/nodes.conf on ${RELEASE}-0"
        cleanup_release; return
    fi

    # Capture the current pod UID so we can detect the replacement.
    local old_uid
    old_uid=$(kctl get pod "${RELEASE}-0" -o jsonpath='{.metadata.uid}' 2>/dev/null)
    if [[ -z ${old_uid} ]]; then
        fail "${name}" "could not read UID of ${RELEASE}-0 before delete"
        cleanup_release; return
    fi

    # Force-delete the pod to trigger pod RECREATION (not in-place
    # container restart). Init containers only run on new pods; SIGKILL
    # of pid 1 alone leaves the same pod object in place and kubelet
    # just restarts the container, skipping the init phase entirely.
    # Force + grace=0 also bypasses the preStop hook and the graceful-
    # shutdown handler, both of which would otherwise rewrite nodes.conf
    # back to a clean state and defeat the test.
    log "Force-deleting ${RELEASE}-0 to trigger pod recreation"
    kctl delete pod "${RELEASE}-0" --force --grace-period=0 \
        --wait=false >/dev/null 2>&1 || true

    # Wait for the StatefulSet controller to create a NEW pod with a
    # different UID (the old one may briefly persist in Terminating
    # state).
    log "Waiting for ${RELEASE}-0 to be recreated with a fresh UID"
    local new_uid
    for _ in $(seq 1 60); do
        new_uid=$(kctl get pod "${RELEASE}-0" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
        if [[ -n ${new_uid} && ${new_uid} != "${old_uid}" ]]; then
            break
        fi
        sleep 2
    done
    if [[ ${new_uid} == "${old_uid}" || -z ${new_uid} ]]; then
        fail "${name}" "${RELEASE}-0 was not recreated (UID still ${old_uid:-empty})"
        cleanup_release; return
    fi

    # Now wait for the new pod to be Ready (init container ran, probe
    # passes — which only happens if cluster_state recovered, which only
    # happens if the refresh worked).
    log "Waiting for the new ${RELEASE}-0 (uid=${new_uid}) to be Ready"
    if ! kctl wait --for=condition=Ready "pod/${RELEASE}-0" --timeout=180s >/dev/null; then
        fail "${name}" "${RELEASE}-0 never became Ready after recreation"
        cleanup_release; return
    fi

    # The post-restart nodes.conf must NOT contain the poison IP — the
    # init container's refresh step replaces it before valkey-server
    # boots. (Valkey itself only writes peers' IPs to nodes.conf as it
    # observes them via gossip; without our pre-boot refresh, the boot
    # would proceed against 192.0.2.99 and the file would stay poisoned.)
    local after
    after=$(kctl exec "${RELEASE}-0" -c "${RELEASE}" -- cat /data/nodes.conf 2>/dev/null)
    if grep -q '192\.0\.2\.99' <<<"${after}"; then
        fail "${name}" "nodes.conf still contains poison IP 192.0.2.99 after restart — refresh did not run. Content: ${after}"
        cleanup_release; return
    fi

    # And the cluster must be functional from pod-0's view — the whole
    # point of the refresh is that it boots into a cluster it can talk
    # to. Poll because gossip needs a moment to re-converge after the
    # restart.
    for _ in $(seq 1 60); do
        s=$(kctl exec "${RELEASE}-0" -c "${RELEASE}" -- \
            valkey-cli cluster info 2>/dev/null \
            | awk -F: '/^cluster_state:/{print $2}' | tr -d '\r\n' || true)
        [[ ${s} == ok ]] && break
        sleep 2
    done
    if [[ ${s} != ok ]]; then
        fail "${name}" "cluster_state=${s:-<unavailable>} after refresh (want ok). nodes.conf was: ${after}"
        cleanup_release; return
    fi

    cleanup_release
    pass "${name}"
}

# ---------------------------------------------------------------------------
# Scenario: probe LOADING-policy is wired correctly on the live workload.
#
# The chart applies a tri-state policy:
#   * startupProbe   — rejects LOADING (gate has teeth during initial RDB load)
#   * livenessProbe  — accepts LOADING (don't kill a replica mid-full-resync)
#   * readinessProbe — rejects LOADING (don't route traffic to a loading pod)
#
# Production regression that motivates this test: a replica in a 38 GB cluster
# hit `cluster_state:fail` after a replication break triggered a full resync;
# the post-resync in-memory load took ~57 s, and livenessProbe
# (failureThreshold=6 * periodSeconds=10s = 60 s) killed the pod just before
# load completed. The kill discarded the freshly-streamed RDB; the next pod
# incarnation triggered yet another full resync. Crash-loop until intervention.
#
# helm-unittest already locks the rendered command strings in via
# matchRegex; this functional test goes one layer further by asserting
# that the live API objects in the cluster carry the right policy. A
# template change that bypasses the helper would slip past unit tests
# but get caught here.
# ---------------------------------------------------------------------------
scenario_probe_loading_policy() {
    local name="probes carry tri-state LOADING policy on live workload"
    log "SCENARIO: ${name}"
    cleanup_release

    if ! hctl install "${RELEASE}" "${CHART_DIR}" \
            --set=cluster.enabled=true \
            --set=cluster.persistence.size=100Mi \
            --set=cluster.shards=3 \
            --set=cluster.replicasPerShard=0 \
            --wait --timeout=300s >/dev/null; then
        fail "${name}" "helm install failed"
        return
    fi

    local startup liveness readiness
    startup=$(kctl get statefulset "${RELEASE}" \
        -o jsonpath='{.spec.template.spec.containers[0].startupProbe.exec.command[2]}')
    liveness=$(kctl get statefulset "${RELEASE}" \
        -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.exec.command[2]}')
    readiness=$(kctl get statefulset "${RELEASE}" \
        -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.exec.command[2]}')

    if grep -q LOADING <<<"${startup}"; then
        fail "${name}" "startupProbe must reject LOADING but accepts it: ${startup}"
        cleanup_release; return
    fi
    if ! grep -q LOADING <<<"${liveness}"; then
        fail "${name}" "livenessProbe must accept LOADING but rejects it: ${liveness}"
        cleanup_release; return
    fi
    if grep -q LOADING <<<"${readiness}"; then
        fail "${name}" "readinessProbe must reject LOADING but accepts it: ${readiness}"
        cleanup_release; return
    fi

    cleanup_release
    pass "${name}"
}

trap 'cleanup_release; cleanup_pair; cleanup_ambient_pair' EXIT

scenario_aclconfig_metrics                       || true
scenario_default_deny_netpol                     || true
scenario_bus_port_hidden                         || true
scenario_readiness_probe_exists                  || true
scenario_two_clusters_isolated                   || true
scenario_isolation_off_lets_merge_happen         || true
scenario_rollout_restart_orderly_failover        || true
scenario_shutdown_on_sigterm_failover            || true
scenario_failover_layers_coexist                 || true
scenario_nodes_conf_ip_refresh                   || true
scenario_probe_loading_policy                    || true
scenario_ambient_authz_blocks_cross_release_meet || true
scenario_ambient_ap_disabled_refused             || true
scenario_ambient_shared_default_sa_refused       || true
scenario_ambient_trustdomain_override            || true
scenario_ambient_prometheus_scrape               || true

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
