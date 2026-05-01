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

trap 'cleanup_release' EXIT

scenario_aclconfig_metrics       || true
scenario_default_deny_netpol     || true
scenario_bus_port_hidden         || true
scenario_readiness_probe_exists  || true

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
