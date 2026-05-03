#!/bin/sh
# preStop hook for cluster-mode Valkey pods: orchestrate an orderly
# CLUSTER FAILOVER before kubelet sends SIGTERM.
#
# Problem this solves
# -------------------
# A rollout restart (or any voluntary pod eviction) sends SIGTERM to Valkey
# and — 30 seconds later by default — SIGKILL. Without a preStop hook, a
# primary pod dies with open client connections; the TCP sockets close
# abruptly, connection pools fill with dead handles, the app errors out on
# every pooled command, and the cluster takes up to cluster-node-timeout
# (15s default) to promote a replica. That is the behaviour the bug report
# describes.
#
# The fix: before the SIGTERM, detect if this pod is a primary; if so, ask
# one of its own replicas to run `CLUSTER FAILOVER`. Valkey then performs
# the canonical orderly handover — the primary pauses new writes, both
# sides sync replication offsets, the replica promotes, the old primary
# demotes to replica. Clients with cluster-topology refresh see the new
# primary immediately via MOVED; existing connections close cleanly as
# part of the demotion. No SIGTERM-during-write window, no pooled dead
# connections, no visible blip.
#
# No-op paths (deliberately best-effort — a failing preStop must never
# block pod shutdown; the old abrupt behaviour is still strictly better
# than hanging in Terminating):
#   * This pod is already a replica — losing a replica is invisible to
#     clients, no failover needed.
#   * Shard has no replicas (cluster.replicasPerShard=0) — nothing to fail
#     over to, accept the abrupt close as a topology choice.
#   * This pod has no healthy replica of its own (all its replicas are
#     marked fail) — skip; FAILOVER would target nothing.
#   * Any vcli command fails — log and exit 0.
#
# Notably NOT a no-op path: cluster_state:fail. That state is expected
# mid-rollout (slots briefly uncovered between restarts). Skipping the
# hook there would perpetuate the degraded state by letting every
# subsequent primary also die abruptly.
#
# This script is templated at Helm render time so it can inline the same
# TLS/auth plumbing the cluster-init script uses. Keeping them separate
# (rather than a shared sourced helper) is intentional: Helm's text-
# template model makes shared sh includes fragile, the code is short, and
# the two scripts evolve independently.
set -eu

log() { echo "preStop: $*" >&2; }

PORT="{{ .Values.service.port }}"
TIMEOUT={{ .Values.cluster.preStopFailover.timeoutSeconds }}

# Self-FQDN (matches what init_config.yaml announces via
# cluster-announce-hostname). Using 127.0.0.1 would work for TCP but
# break TLS SAN verification — the server cert's SAN lists the FQDN, not
# the loopback. Same rationale applies to the replica endpoint below.
SELF_FQDN="${HOSTNAME}.{{ include "valkey.headlessServiceName" . }}.{{ .Release.Namespace }}.svc.{{ .Values.clusterDomain }}"

{{- if and .Values.auth.enabled .Values.auth.aclUsers }}
{{- $replUsername := .Values.cluster.replicationUser }}
{{- $replUser := index .Values.auth.aclUsers $replUsername }}
{{- $replPasswordKey := $replUser.passwordKey | default $replUsername }}
{{- if .Values.auth.usersExistingSecret }}
if [ -f "/valkey-users-secret/{{ $replPasswordKey }}" ]; then
  REDISCLI_AUTH=$(cat "/valkey-users-secret/{{ $replPasswordKey }}")
elif [ -f "/valkey-auth-secret/{{ $replUsername }}-password" ]; then
  REDISCLI_AUTH=$(cat "/valkey-auth-secret/{{ $replUsername }}-password")
else
  log "no password found for user {{ $replUsername }}; cannot authenticate preStop"
  exit 0
fi
{{- else }}
if [ -f "/valkey-auth-secret/{{ $replUsername }}-password" ]; then
  REDISCLI_AUTH=$(cat "/valkey-auth-secret/{{ $replUsername }}-password")
else
  log "no password found for user {{ $replUsername }}; cannot authenticate preStop"
  exit 0
fi
{{- end }}
export REDISCLI_AUTH
{{- end }}

vcli() {
{{- if .Values.tls.enabled }}
  valkey-cli --no-auth-warning --tls --cacert "/tls/{{ .Values.tls.caPublicKey }}" "$@"
{{- else }}
  valkey-cli --no-auth-warning "$@"
{{- end }}
}

# We do NOT gate on cluster_state here. A rollout restarts pods one at a
# time, and between restarts this node sees cluster_state:fail until
# gossip observes the previous pod rejoin — exactly the window this
# preStop is meant to close. Skipping FAILOVER there would defeat the
# hook: without it, SIGTERM takes the primary's slots offline and the
# next pod also sees cluster_state:fail, perpetuating the degraded state
# for the rest of the rollout. We rely instead on CLUSTER FAILOVER's
# own preconditions (a healthy, caught-up replica) to decide whether the
# handover is safe.
role=$(vcli -h "${SELF_FQDN}" -p "${PORT}" info replication 2>/dev/null | awk -F: '/^role:/{print $2}' | tr -d '\r\n' || true)
case "${role}" in
  master) ;;
  slave|replica)
    log "role=${role}; no failover needed"
    exit 0
    ;;
  *)
    log "unexpected role=${role:-<unknown>}; not attempting failover"
    exit 0
    ;;
esac

my_id=$(vcli -h "${SELF_FQDN}" -p "${PORT}" cluster myid 2>/dev/null | tr -d '\r\n' || true)
if [ -z "${my_id}" ]; then
  log "cluster myid empty; not attempting failover"
  exit 0
fi

# CLUSTER REPLICAS <my-id> returns a subset of CLUSTER NODES, one line per
# replica of this primary, in the same eight-field format. We want a live
# (non-failing), online replica. Field 2 is the announce endpoint
# "host:port@busport[,hostname]"; Helm sets
# cluster-preferred-endpoint-type=hostname in init_config.yaml, so the
# host half is a DNS name that matches the TLS SAN when TLS is enabled.
replica_line=$(vcli -h "${SELF_FQDN}" -p "${PORT}" cluster replicas "${my_id}" 2>/dev/null \
  | awk '!/fail/ && NF' \
  | head -n1 || true)
if [ -z "${replica_line}" ]; then
  log "no healthy replica for this primary; skipping failover"
  exit 0
fi

endpoint=$(printf '%s\n' "${replica_line}" | awk '{print $2}' | cut -d@ -f1)
replica_host=${endpoint%:*}
replica_port=${endpoint##*:}

if [ -z "${replica_host}" ] || [ -z "${replica_port}" ]; then
  log "could not parse replica endpoint from '${replica_line}'; skipping failover"
  exit 0
fi

log "primary ${my_id}; asking replica ${replica_host}:${replica_port} to take over"

# Plain CLUSTER FAILOVER (no FORCE/TAKEOVER) is the graceful path: the
# replica negotiates with the primary, waits for replication-offset sync,
# then promotes. If the replica is too far behind or the primary is
# unreachable, it returns an error — we then exit 0 and let SIGTERM run.
if ! vcli -h "${replica_host}" -p "${replica_port}" cluster failover 2>/dev/null; then
  log "CLUSTER FAILOVER rejected; proceeding with abrupt shutdown"
  exit 0
fi

# CLUSTER FAILOVER returns OK as soon as the replica accepts the request;
# the actual role flip is asynchronous. Poll our own INFO until we see
# role=slave (or give up on TIMEOUT).
deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  now=$(date +%s)
  if [ "${now}" -ge "${deadline}" ]; then
    log "timed out after ${TIMEOUT}s waiting for demotion; proceeding with shutdown"
    exit 0
  fi
  cur_role=$(vcli -h "${SELF_FQDN}" -p "${PORT}" info replication 2>/dev/null | awk -F: '/^role:/{print $2}' | tr -d '\r\n' || true)
  if [ "${cur_role}" = "slave" ] || [ "${cur_role}" = "replica" ]; then
    log "demoted to ${cur_role}; handover complete"
    exit 0
  fi
  sleep 1
done
