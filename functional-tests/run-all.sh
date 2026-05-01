#!/usr/bin/env bash
# Drive every scenario in the matrix, sequentially. Assumes `setup.sh`
# has already created the kind cluster and fixtures.

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "${HERE}/lib.sh"

SCENARIOS=(
    # tls auth shard rep
    "off off off off"
    "off off off on"
    "off off on  off"
    "off off on  on"
    "off on  off off"
    "off on  off on"
    "off on  on  off"
    "off on  on  on"
    "on  off off off"
    "on  off off on"
    "on  off on  off"
    "on  off on  on"
    "on  on  off off"
    "on  on  off on"
    "on  on  on  off"
    "on  on  on  on"
)

# Optional filter: skip scenarios matching the first arg, e.g. `./run-all.sh tls=on`.
# Kept intentionally simple — pass one or more "key=on" / "key=off" selectors.
matches() {
    local spec=$1 tls=$2 auth=$3 shard=$4 rep=$5
    for sel in ${FILTER:-}; do
        local k=${sel%=*} v=${sel#*=}
        local have
        case "${k}" in
            tls)   have=${tls} ;;
            auth)  have=${auth} ;;
            shard) have=${shard} ;;
            rep)   have=${rep} ;;
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
    read -r tls auth shard rep <<<"${s}"
    if ! matches "${s}" "${tls}" "${auth}" "${shard}" "${rep}"; then
        continue
    fi

    log "SCENARIO: tls=${tls} auth=${auth} shard=${shard} rep=${rep}"
    if "${HERE}/run-scenario.sh" "${tls}" "${auth}" "${shard}" "${rep}"; then
        passed=$(( passed + 1 ))
    else
        failed=$(( failed + 1 ))
        failures+=("tls=${tls} auth=${auth} shard=${shard} rep=${rep}")
    fi
done

echo
log "Summary: ${passed} passed, ${failed} failed"
if (( failed > 0 )); then
    printf '  failed: %s\n' "${failures[@]}"
    exit 1
fi
