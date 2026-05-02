#!/usr/bin/env bash
# Drive every scenario in the matrix, sequentially. Assumes `setup.sh`
# has already created the kind cluster and fixtures.

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "${HERE}/lib.sh"

# 32 scenarios: every combination of tls/auth/shard/rep/istio.
SCENARIOS=()
for istio in off on; do
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

# Optional filter: `FILTER='tls=on istio=on'` runs only matching scenarios.
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
            istio) have=${istio} ;;
            *) echo "bad filter key: ${k}" >&2; exit 2 ;;
        esac
        [[ ${have} == "${v}" ]] || return 1
    done
    return 0
}

passed=0
failed=0
failures=()

for s in "${SCENARIOS[@]}"; do
    # shellcheck disable=SC2086
    read -r tls auth shard rep istio <<<"${s}"
    if ! matches "${tls}" "${auth}" "${shard}" "${rep}" "${istio}"; then
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
log "Matrix summary: ${passed} passed, ${failed} failed"
if (( failed > 0 )); then
    printf '  failed: %s\n' "${failures[@]}"
    exit 1
fi

# Extra, non-matrix regressions (aclConfig+metrics, default-deny netpol, etc).
# Skipped when FILTER is set — filters are matrix-scoped, so the extras
# wouldn't match anyway and running them would be surprising.
if [[ -z ${FILTER:-} ]]; then
    "${HERE}/run-extra-scenarios.sh"
    # Ambient-mesh regressions. Self-skipping when ztunnel isn't installed
    # (e.g. against an older cluster with only the `demo` profile).
    "${HERE}/run-ambient-scenarios.sh"
fi
