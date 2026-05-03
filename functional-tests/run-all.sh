#!/usr/bin/env bash
# Drive every scenario in the matrix, sequentially. Assumes `setup.sh`
# has already created the kind cluster and fixtures.

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "${HERE}/lib.sh"

# 48 scenarios: every combination of tls/auth/shard/rep × istio=
# off|sidecar|ambient. The istio dimension is three-valued rather than two
# because sidecar and ambient share almost nothing below the chart-owned
# templates — different label paths, different mTLS enforcement points
# (Envoy vs ztunnel), different rendered resources (DestinationRule only
# in sidecar; AuthorizationPolicy in both but enforced differently). Keep
# them both in the matrix so a regression in one mode can't hide behind a
# passing result in the other.
SCENARIOS=()
for istio in off sidecar ambient; do
    for tls in off on; do
        for auth in off on; do
            for shard in off on; do
                for rep in off on; do
                    SCENARIOS+=("${tls} ${auth} ${shard} ${rep} ${istio}")
                done
            done
        done
    done
done

# Optional filter: `FILTER='tls=on istio=ambient'` runs only matching
# scenarios. Filter values for `istio` are off|sidecar|ambient; `on` is
# accepted as an alias for "sidecar or ambient" to keep old habits working.
matches() {
    local tls=$1 auth=$2 shard=$3 rep=$4 istio=$5
    for sel in ${FILTER:-}; do
        local k=${sel%=*} v=${sel#*=}
        local have
        case "${k}" in
            tls)   have=${tls} ;;
            auth)  have=${auth} ;;
            shard) have=${shard} ;;
            rep)   have=${rep} ;;
            istio)
                if [[ ${v} == on ]]; then
                    [[ ${istio} == sidecar || ${istio} == ambient ]] || return 1
                    continue
                fi
                have=${istio}
                ;;
            *) echo "bad filter key: ${k}" >&2; exit 2 ;;
        esac
        [[ ${have} == "${v}" ]] || return 1
    done
    return 0
}

passed=0
failed=0
skipped=0
failures=()

for s in "${SCENARIOS[@]}"; do
    # shellcheck disable=SC2086
    read -r tls auth shard rep istio <<<"${s}"
    if ! matches "${tls}" "${auth}" "${shard}" "${rep}" "${istio}"; then
        continue
    fi

    # Ambient scenarios require ztunnel to be installed. setup.sh now
    # installs the ambient profile by default, but a user running against
    # a pre-existing cluster might have only the sidecar data plane —
    # skip rather than fail in that case so the rest of the matrix still
    # runs.
    if [[ ${istio} == ambient ]] && ! istio_ambient_installed; then
        log "SKIP: tls=${tls} auth=${auth} shard=${shard} rep=${rep} istio=${istio} (ztunnel not installed)"
        skipped=$(( skipped + 1 ))
        continue
    fi

    log "SCENARIO: tls=${tls} auth=${auth} shard=${shard} rep=${rep} istio=${istio}"
    if "${HERE}/run-scenario.sh" "${tls}" "${auth}" "${shard}" "${rep}" "${istio}"; then
        passed=$(( passed + 1 ))
    else
        failed=$(( failed + 1 ))
        failures+=("tls=${tls} auth=${auth} shard=${shard} rep=${rep} istio=${istio}")
    fi
done

echo
log "Matrix summary: ${passed} passed, ${failed} failed, ${skipped} skipped"
if (( failed > 0 )); then
    printf '  failed: %s\n' "${failures[@]}"
    exit 1
fi

# Extra, non-matrix regressions (aclConfig+metrics, default-deny netpol,
# cross-release MEET isolation, ambient validator footguns, Prometheus
# scraping, etc.). Each one is independent of the tls/auth/shard/rep
# combinations — folding them into the matrix would just pay the
# install/teardown cost N times to exercise the same single assertion.
# Skipped when FILTER is set: filters are matrix-scoped, so the extras
# wouldn't match anyway and running them would be surprising.
if [[ -z ${FILTER:-} ]]; then
    "${HERE}/run-extra-scenarios.sh"
fi
