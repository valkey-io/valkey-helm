#!/bin/sh
set -eu

# --- Configuration & Initial Checks ---
if [ "${CLUSTER_NODE_COUNT}" -eq "1" ]; then
    echo "Single node deployment. Skipping cluster initialization"
    exit 0
fi

REPLICAS_PER_SHARD=${CLUSTER_REPLICAS_PER_SHARD:-1}
PRIMARIES=$(( CLUSTER_NODE_COUNT / (1 + REPLICAS_PER_SHARD) ))

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
  echo "ERROR: No password found for cluster replication user {{ $replUsername }}" >&2
  exit 1
fi
{{- else }}
if [ -f "/valkey-auth-secret/{{ $replUsername }}-password" ]; then
  REDISCLI_AUTH=$(cat "/valkey-auth-secret/{{ $replUsername }}-password")
else
  echo "ERROR: No password found for cluster replication user {{ $replUsername }}" >&2
  exit 1
fi
{{- end }}
# Valkey/Redis clients honour REDISCLI_AUTH, which avoids passing the password
# on the command line (where it would leak via `ps` and trip over shell
# metacharacters).
export REDISCLI_AUTH
{{- end }}

# vcli: thin wrapper that inherits REDISCLI_AUTH and always adds TLS args when
# configured. Callers pass only host/port/subcommand.
vcli() {
{{- if .Values.tls.enabled }}
  valkey-cli --no-auth-warning --tls --cacert "/tls/{{ .Values.tls.caPublicKey }}" "$@"
{{- else }}
  valkey-cli --no-auth-warning "$@"
{{- end }}
}

echo "Cluster init job starting. Total nodes: ${CLUSTER_NODE_COUNT}, Primaries: ${PRIMARIES}, Replicas per shard: ${REPLICAS_PER_SHARD}"

HEADLESS_SVC="{{ include "valkey.headlessServiceName" . }}"
NAMESPACE="{{ .Release.Namespace }}"
CLUSTER_DOMAIN="{{ .Values.clusterDomain }}"
PORT="{{ .Values.service.port }}"
FULLNAME="{{ include "valkey.fullname" . }}"

node_host() { echo "${FULLNAME}-$1.${HEADLESS_SVC}.${NAMESPACE}.svc.${CLUSTER_DOMAIN}"; }

# --- Wait for all Valkey nodes to be ready ---
for i in $(seq 0 $((CLUSTER_NODE_COUNT - 1))); do
  NODE_HOST=$(node_host "${i}")
  until vcli -h "${NODE_HOST}" -p "${PORT}" ping 2>/dev/null | grep -q "PONG"; do
    echo "Waiting for ${NODE_HOST} to be ready..."
    sleep 2
  done
  echo "Node ${NODE_HOST} is ready."
done

echo "All ${CLUSTER_NODE_COUNT} nodes are ready."

# --- Discover Existing Cluster ---
HEALTHY_NODE=""
for i in $(seq 0 $((CLUSTER_NODE_COUNT - 1))); do
  NODE_HOST=$(node_host "${i}")
  if vcli -h "${NODE_HOST}" -p "${PORT}" cluster info 2>/dev/null | grep -q "cluster_state:ok"; then
    HEALTHY_NODE="${NODE_HOST}"
    echo "Found healthy cluster node: ${HEALTHY_NODE}"
    break
  fi
done

# --- Logic for Joining an Existing Cluster (scaling up) ---
if [ -n "${HEALTHY_NODE}" ]; then
  echo "Existing cluster found. Checking for new nodes to add..."

  KNOWN_NODES=$(vcli -h "${HEALTHY_NODE}" -p "${PORT}" cluster nodes 2>/dev/null)

  NEW_NODE_COUNT=0
  for i in $(seq 0 $((CLUSTER_NODE_COUNT - 1))); do
    NODE_HOST=$(node_host "${i}")
    NODE_IP=$(getent hosts "${NODE_HOST}" | awk '{print $1}')

    if echo "${KNOWN_NODES}" | grep -v "fail" | grep -q "${NODE_IP}:${PORT}"; then
      echo "Node ${NODE_HOST} (${NODE_IP}) already in cluster."
      continue
    fi

    echo "New node found: ${NODE_HOST} (${NODE_IP}). Adding to cluster..."
    NEW_NODE_COUNT=$((NEW_NODE_COUNT + 1))

    # Forget any old, failed instance of this node
    FAILED_NODE_ID=$(echo "${KNOWN_NODES}" | grep "${NODE_IP}:${PORT}" | grep "fail" | awk '{print $1}' || true)
    if [ -n "${FAILED_NODE_ID}" ]; then
      echo "Found node IP (${NODE_IP}) marked as failed with ID ${FAILED_NODE_ID}. Forgetting it..."
      vcli --cluster call "${HEALTHY_NODE}:${PORT}" cluster forget "${FAILED_NODE_ID}" > /dev/null 2>&1 || true
      sleep 3
    fi

    # Meet the cluster via the new node
    HEALTHY_NODE_IP=$(getent hosts "${HEALTHY_NODE}" | awk '{print $1}')
    echo "Sending CLUSTER MEET from ${NODE_HOST} to ${HEALTHY_NODE} (${HEALTHY_NODE_IP})"
    vcli -h "${NODE_HOST}" -p "${PORT}" cluster meet "${HEALTHY_NODE_IP}" "${PORT}"
  done

  if [ "${NEW_NODE_COUNT}" -eq 0 ]; then
    echo "No new nodes to add. Cluster is up to date."
    exit 0
  fi

  sleep 5

  # Assign roles to new nodes: find masters needing replicas
  for i in $(seq 0 $((CLUSTER_NODE_COUNT - 1))); do
    NODE_HOST=$(node_host "${i}")
    NODE_ID=$(vcli -h "${NODE_HOST}" -p "${PORT}" cluster myid)

    # Re-fetch cluster state from healthy node for current view
    CURRENT_NODES=$(vcli -h "${HEALTHY_NODE}" -p "${PORT}" cluster nodes)

    # Check if this node is a master with no slots (new node)
    NODE_INFO=$(echo "${CURRENT_NODES}" | grep "${NODE_ID}")
    IS_MASTER=$(echo "${NODE_INFO}" | grep -c "master" || true)
    HAS_SLOTS=$(echo "${NODE_INFO}" | awk '{for(i=9;i<=NF;i++) print $i}' | head -1)

    if [ "${IS_MASTER}" -gt 0 ] && [ -z "${HAS_SLOTS}" ]; then
      echo "Node ${NODE_HOST} is an empty master. Searching for a master to replicate..."

      TARGET_MASTER_ID=$(echo "${CURRENT_NODES}" | awk -v replicas_needed="${REPLICAS_PER_SHARD}" -v my_id="${NODE_ID}" '
        /master/ && !/fail/ { masters[$1] = 1 }
        /slave/ && !/fail/ { master_replicas[$4]++ }
        END {
          for (master_id in masters) {
            if ( master_id != my_id && (master_replicas[master_id] < replicas_needed || master_replicas[master_id] == "") ) {
              print master_id
              exit
            }
          }
        }
      ')

      if [ -n "${TARGET_MASTER_ID}" ]; then
        echo "Found target master ${TARGET_MASTER_ID} that needs a replica."
        if vcli -h "${NODE_HOST}" -p "${PORT}" cluster replicate "${TARGET_MASTER_ID}"; then
          echo "Successfully configured ${NODE_HOST} as a replica for ${TARGET_MASTER_ID}."
        else
          echo "WARNING: Failed to replicate master ${TARGET_MASTER_ID} from ${NODE_HOST}."
        fi
      fi
    fi
  done

  # Rebalance if needed
  echo "Attempting cluster rebalance..."

  PROPAGATION_ATTEMPTS=0
  MAX_PROPAGATION_ATTEMPTS=60
  while [ ${PROPAGATION_ATTEMPTS} -lt ${MAX_PROPAGATION_ATTEMPTS} ]; do
    CLUSTER_STATE=$(vcli -h "${HEALTHY_NODE}" -p "${PORT}" cluster info 2>/dev/null | grep "cluster_state:" | cut -d: -f2 | tr -d '\r\n')
    if [ "${CLUSTER_STATE}" = "ok" ]; then
      echo "Cluster state is OK. Proceeding with rebalance."
      break
    fi
    echo "Cluster state is ${CLUSTER_STATE}. Waiting for propagation... (${PROPAGATION_ATTEMPTS}/${MAX_PROPAGATION_ATTEMPTS})"
    PROPAGATION_ATTEMPTS=$((PROPAGATION_ATTEMPTS + 1))
    sleep 5
  done

  vcli --cluster rebalance "${HEALTHY_NODE}:${PORT}" --cluster-use-empty-masters --cluster-yes || true

  echo "Cluster update completed."
  exit 0
fi

# --- Create New Cluster ---
echo "No existing cluster found. Creating new cluster..."
NODES=""
for i in $(seq 0 $((CLUSTER_NODE_COUNT - 1))); do
  NODE_HOST=$(node_host "${i}")
  NODES="${NODES} ${NODE_HOST}:${PORT}"
done

# Allow time for cluster-enabled nodes to fully initialize
sleep 10

echo "Creating cluster with nodes:${NODES}"
# shellcheck disable=SC2086
echo "yes" | vcli --cluster create ${NODES} --cluster-replicas "${REPLICAS_PER_SHARD}"
echo "Cluster created successfully."

exit 0
