#!/bin/sh
set -e

# --- Configuration & Initial Checks ---
if [ "${CLUSTER_NODE_COUNT}" -eq "1" ]; then
    echo "Single node deployment. Skipping cluster initialization"
    exit 0
fi

REPLICAS_PER_SHARD=${CLUSTER_REPLICAS_PER_SHARD:-1}
PRIMARIES=$(( CLUSTER_NODE_COUNT / (1 + REPLICAS_PER_SHARD) ))

{{- if and .Values.auth.enabled .Values.auth.aclUsers }}
# Get password for cluster replication user from mounted secret
{{- $replUsername := .Values.cluster.replicationUser }}
{{- $replUser := index .Values.auth.aclUsers $replUsername }}
{{- $replPasswordKey := $replUser.passwordKey | default $replUsername }}
{{- if .Values.auth.usersExistingSecret }}
if [ -f "/valkey-users-secret/{{ $replPasswordKey }}" ]; then
  AUTH_PASSWORD=$(cat "/valkey-users-secret/{{ $replPasswordKey }}")
elif [ -f "/valkey-auth-secret/{{ $replUsername }}-password" ]; then
  AUTH_PASSWORD=$(cat "/valkey-auth-secret/{{ $replUsername }}-password")
else
  echo "ERROR: No password found for cluster replication user {{ $replUsername }}"
  exit 1
fi
{{- else }}
if [ -f "/valkey-auth-secret/{{ $replUsername }}-password" ]; then
  AUTH_PASSWORD=$(cat "/valkey-auth-secret/{{ $replUsername }}-password")
else
  echo "ERROR: No password found for cluster replication user {{ $replUsername }}"
  exit 1
fi
{{- end }}
AUTH_OPTION="-a ${AUTH_PASSWORD}"
{{- else }}
AUTH_OPTION=""
{{- end }}

{{- if .Values.tls.enabled }}
TLS_OPTION="--tls --cacert /tls/{{ .Values.tls.caPublicKey }}"
{{- else }}
TLS_OPTION=""
{{- end }}

echo "Cluster init job starting. Total nodes: ${CLUSTER_NODE_COUNT}, Primaries: ${PRIMARIES}, Replicas per shard: ${REPLICAS_PER_SHARD}"

HEADLESS_SVC="{{ include "valkey.headlessServiceName" . }}"
NAMESPACE="{{ .Release.Namespace }}"
CLUSTER_DOMAIN="{{ .Values.clusterDomain }}"

# --- Wait for all Valkey nodes to be ready ---
for i in $(seq 0 $((CLUSTER_NODE_COUNT - 1))); do
  NODE_HOST="{{ include "valkey.fullname" . }}-${i}.${HEADLESS_SVC}.${NAMESPACE}.svc.${CLUSTER_DOMAIN}"
  until valkey-cli ${AUTH_OPTION} ${TLS_OPTION} -h "${NODE_HOST}" -p {{ .Values.service.port }} ping 2>/dev/null | grep -q "PONG"; do
    echo "Waiting for ${NODE_HOST} to be ready..."
    sleep 2
  done
  echo "Node ${NODE_HOST} is ready."
done

echo "All ${CLUSTER_NODE_COUNT} nodes are ready."

# --- Discover Existing Cluster ---
HEALTHY_NODE=""
for i in $(seq 0 $((CLUSTER_NODE_COUNT - 1))); do
  NODE_HOST="{{ include "valkey.fullname" . }}-${i}.${HEADLESS_SVC}.${NAMESPACE}.svc.${CLUSTER_DOMAIN}"
  if valkey-cli ${AUTH_OPTION} ${TLS_OPTION} -h "${NODE_HOST}" -p {{ .Values.service.port }} cluster info 2>/dev/null | grep -q "cluster_state:ok"; then
    HEALTHY_NODE="${NODE_HOST}"
    echo "Found healthy cluster node: ${HEALTHY_NODE}"
    break
  fi
done

# --- Logic for Joining an Existing Cluster (scaling up) ---
if [ -n "${HEALTHY_NODE}" ]; then
  echo "Existing cluster found. Checking for new nodes to add..."

  KNOWN_NODES=$(valkey-cli ${AUTH_OPTION} ${TLS_OPTION} -h "${HEALTHY_NODE}" -p {{ .Values.service.port }} cluster nodes 2>/dev/null)

  NEW_NODE_COUNT=0
  for i in $(seq 0 $((CLUSTER_NODE_COUNT - 1))); do
    NODE_HOST="{{ include "valkey.fullname" . }}-${i}.${HEADLESS_SVC}.${NAMESPACE}.svc.${CLUSTER_DOMAIN}"
    NODE_IP=$(getent hosts "${NODE_HOST}" | awk '{print $1}')

    if echo "${KNOWN_NODES}" | grep -v "fail" | grep -q "${NODE_IP}:{{ .Values.service.port }}"; then
      echo "Node ${NODE_HOST} (${NODE_IP}) already in cluster."
      continue
    fi

    echo "New node found: ${NODE_HOST} (${NODE_IP}). Adding to cluster..."
    NEW_NODE_COUNT=$((NEW_NODE_COUNT + 1))

    # Forget any old, failed instance of this node
    FAILED_NODE_ID=$(echo "${KNOWN_NODES}" | grep "${NODE_IP}:{{ .Values.service.port }}" | grep "fail" | awk '{print $1}' || echo "")
    if [ -n "${FAILED_NODE_ID}" ]; then
      echo "Found node IP (${NODE_IP}) marked as failed with ID ${FAILED_NODE_ID}. Forgetting it..."
      valkey-cli ${AUTH_OPTION} ${TLS_OPTION} --cluster call "${HEALTHY_NODE}:{{ .Values.service.port }}" cluster forget "${FAILED_NODE_ID}" > /dev/null 2>&1 || true
      sleep 3
    fi

    # Meet the cluster via the new node
    HEALTHY_NODE_IP=$(getent hosts "${HEALTHY_NODE}" | awk '{print $1}')
    echo "Sending CLUSTER MEET from ${NODE_HOST} to ${HEALTHY_NODE} (${HEALTHY_NODE_IP})"
    valkey-cli ${AUTH_OPTION} ${TLS_OPTION} -h "${NODE_HOST}" -p {{ .Values.service.port }} cluster meet "${HEALTHY_NODE_IP}" {{ .Values.service.port }}
  done

  if [ "${NEW_NODE_COUNT}" -eq 0 ]; then
    echo "No new nodes to add. Cluster is up to date."
    exit 0
  fi

  sleep 5

  # Assign roles to new nodes: find masters needing replicas
  for i in $(seq 0 $((CLUSTER_NODE_COUNT - 1))); do
    NODE_HOST="{{ include "valkey.fullname" . }}-${i}.${HEADLESS_SVC}.${NAMESPACE}.svc.${CLUSTER_DOMAIN}"
    NODE_ID=$(valkey-cli ${AUTH_OPTION} ${TLS_OPTION} -h "${NODE_HOST}" -p {{ .Values.service.port }} cluster myid)

    # Re-fetch cluster state from healthy node for current view
    CURRENT_NODES=$(valkey-cli ${AUTH_OPTION} ${TLS_OPTION} -h "${HEALTHY_NODE}" -p {{ .Values.service.port }} cluster nodes)

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
        if valkey-cli ${AUTH_OPTION} ${TLS_OPTION} -h "${NODE_HOST}" -p {{ .Values.service.port }} cluster replicate "${TARGET_MASTER_ID}"; then
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
    CLUSTER_STATE=$(valkey-cli ${AUTH_OPTION} ${TLS_OPTION} -h "${HEALTHY_NODE}" -p {{ .Values.service.port }} cluster info 2>/dev/null | grep "cluster_state:" | cut -d: -f2 | tr -d '\r\n')
    if [ "${CLUSTER_STATE}" = "ok" ]; then
      echo "Cluster state is OK. Proceeding with rebalance."
      break
    fi
    echo "Cluster state is ${CLUSTER_STATE}. Waiting for propagation... (${PROPAGATION_ATTEMPTS}/${MAX_PROPAGATION_ATTEMPTS})"
    PROPAGATION_ATTEMPTS=$((PROPAGATION_ATTEMPTS + 1))
    sleep 5
  done

  valkey-cli ${AUTH_OPTION} ${TLS_OPTION} --cluster rebalance "${HEALTHY_NODE}:{{ .Values.service.port }}" --cluster-use-empty-masters --cluster-yes || true

  echo "Cluster update completed."
  exit 0
fi

# --- Create New Cluster ---
echo "No existing cluster found. Creating new cluster..."
NODES=""
for i in $(seq 0 $((CLUSTER_NODE_COUNT - 1))); do
  NODE_HOST="{{ include "valkey.fullname" . }}-${i}.${HEADLESS_SVC}.${NAMESPACE}.svc.${CLUSTER_DOMAIN}"
  NODES="${NODES} ${NODE_HOST}:{{ .Values.service.port }}"
done

# Allow time for cluster-enabled nodes to fully initialize
sleep 10

echo "Creating cluster with nodes: ${NODES}"
echo "yes" | valkey-cli ${AUTH_OPTION} ${TLS_OPTION} --cluster create ${NODES} --cluster-replicas "${REPLICAS_PER_SHARD}"
echo "Cluster created successfully."

exit 0
