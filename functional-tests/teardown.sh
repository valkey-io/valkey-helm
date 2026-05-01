#!/usr/bin/env bash
# Remove the shared fixtures and (optionally) the kind cluster itself.
#
# Usage:
#   ./teardown.sh           # remove fixtures, keep cluster
#   ./teardown.sh --cluster # also delete the kind cluster

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "${HERE}/lib.sh"

DELETE_CLUSTER=0
for arg in "$@"; do
    case "${arg}" in
        --cluster) DELETE_CLUSTER=1 ;;
        *) echo "unknown arg: ${arg}" >&2; exit 2 ;;
    esac
done

if kind get clusters | grep -Fxq "${CLUSTER_NAME}"; then
    log "Removing fixtures from ${CLUSTER_NAME}"
    # Best-effort: any lingering release + PVCs.
    hctl uninstall "${RELEASE}"                                    2>/dev/null || true
    kctl delete pvc --selector="app.kubernetes.io/instance=${RELEASE}" --ignore-not-found
    kctl delete pod    "${TESTBENCH_POD}"                             --ignore-not-found
    kctl delete secret "${AUTH_SECRET}" "${TLS_SECRET}"               --ignore-not-found
fi

if (( DELETE_CLUSTER )); then
    log "Deleting kind cluster ${CLUSTER_NAME}"
    kind delete cluster --name "${CLUSTER_NAME}"
fi
