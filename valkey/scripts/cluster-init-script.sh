#!/bin/sh
set -e

# --- Configuration & Initial Checks ---
if [ "${CLUSTER_NODE_COUNT}" -eq "1" ]; then
    echo "Single node deployment. Skipping cluster initialization"
    exit 0
fi

ORDINAL=$(echo "${POD_NAME}" | rev | cut -d'-' -f1 | rev)
REPLICAS_PER_SHARD=${CLUSTER_REPLICAS_PER_SHARD:-1}
PRIMARIES=$(( CLUSTER_NODE_COUNT / (1 + REPLICAS_PER_SHARD) ))

{{- if and .Values.auth.enabled .Values.auth.aclUsers }}
AUTH_OPTION="-a $(cat /etc/valkey/users.acl | grep '^user {{ .Values.cluster.replicationUser }} ' | sed 's/.*#\([a-f0-9]*\).*/\1/' | head -1)"
# If we have the password from environment, use that instead
if [ -n "${VALKEY_AUTH_PASSWORD}" ]; then
  AUTH_OPTION="-a ${VALKEY_AUTH_PASSWORD}"
fi
{{- else }}
AUTH_OPTION=""
{{- end }}

{{- if .Values.tls.enabled }}
TLS_OPTION="--tls --cacert /tls/{{ .Values.tls.caPublicKey }}"
{{- else }}
TLS_OPTION=""
{{- end }}

echo "Initializing as ordinal ${ORDINAL}. Total nodes: ${CLUSTER_NODE_COUNT}, Primaries: ${PRIMARIES}, Replicas per shard: ${REPLICAS_PER_SHARD}"

HEADLESS_SVC="{{ include "valkey.headlessServiceName" . }}"
NAMESPACE="{{ .Release.Namespace }}"
CLUSTER_DOMAIN="{{ .Values.clusterDomain }}"
MY_IP=$(hostname -i)

# Wait for the local Valkey server process to start
until valkey-cli ${AUTH_OPTION} ${TLS_OPTION} -h localhost -p {{ .Values.service.port }} ping 2>/dev/null | grep -q "PONG"; do
  echo "Waiting for local Valkey to start..."
  sleep 2
done
echo "Local Valkey is ready at ${MY_IP}"

# --- Discover Existing Cluster ---
HEALTHY_NODE=""
for i in $(seq 0 $((CLUSTER_NODE_COUNT - 1))); do
  if [ "${i}" != "${ORDINAL}" ]; then
    NODE_HOST="{{ include "valkey.fullname" . }}-${i}.${HEADLESS_SVC}.${NAMESPACE}.svc.${CLUSTER_DOMAIN}"
    if valkey-cli ${AUTH_OPTION} ${TLS_OPTION} -h "${NODE_HOST}" -p {{ .Values.service.port }} cluster info 2>/dev/null | grep -q "cluster_state:ok"; then
      HEALTHY_NODE="${NODE_HOST}"
      echo "Found healthy cluster node: ${HEALTHY_NODE}"
      break
    fi
  fi
done

# --- Logic for Joining an Existing Cluster ---
if [ -n "${HEALTHY_NODE}" ]; then
  echo "Healthy cluster found. Attempting to join..."

  # 1. Forget any old, failed instance of ourselves
  FAILED_NODE_ID=$(valkey-cli ${AUTH_OPTION} ${TLS_OPTION} -h "${HEALTHY_NODE}" -p {{ .Values.service.port }} cluster nodes 2>/dev/null | grep "${MY_IP}:{{ .Values.service.port }}" | grep "fail" | awk '{print $1}' || echo "")
  if [ -n "${FAILED_NODE_ID}" ]; then
    echo "Found my IP (${MY_IP}) marked as failed with ID ${FAILED_NODE_ID}. Forgetting it..."
    valkey-cli ${AUTH_OPTION} ${TLS_OPTION} --cluster call "${HEALTHY_NODE}:{{ .Values.service.port }}" cluster forget "${FAILED_NODE_ID}" > /dev/null 2>&1 || true
    sleep 3
  fi

  # 2. Meet the cluster
  HEALTHY_NODE_IP=$(getent hosts "${HEALTHY_NODE}" | awk '{print $1}')
  echo "Sending CLUSTER MEET to ${HEALTHY_NODE} (${HEALTHY_NODE_IP})"
  valkey-cli ${AUTH_OPTION} ${TLS_OPTION} -h localhost -p {{ .Values.service.port }} cluster meet "${HEALTHY_NODE_IP}" {{ .Values.service.port }}
  sleep 5

  # 3. Find an orphaned master and become its replica
  echo "Searching for a master to replicate..."

  MY_NODE_ID=$(valkey-cli ${AUTH_OPTION} ${TLS_OPTION} -h localhost -p {{ .Values.service.port }} cluster myid)
  echo "My Node ID is ${MY_NODE_ID}"

  # This prevents race conditions from the order of 'cluster nodes' output
  TARGET_MASTER_ID=$(valkey-cli ${AUTH_OPTION} ${TLS_OPTION} -h "${HEALTHY_NODE}" -p {{ .Values.service.port }} cluster nodes | awk -v replicas_needed="${REPLICAS_PER_SHARD}" -v my_id="${MY_NODE_ID}" '
    # Pass 1: Build maps of masters and replica counts
    /master/ && !/fail/ { masters[$1] = 1 }
    /slave/ && !/fail/ { master_replicas[$4]++ }
    END {
      # Pass 2: Iterate over the masters we found
      for (master_id in masters) {
        # Check if it needs a replica AND it is not ourself
        if ( master_id != my_id && (master_replicas[master_id] < replicas_needed || master_replicas[master_id] == "") ) {
          print master_id
          exit # Found a suitable master
        }
      }
    }
  ')

  if [ -n "${TARGET_MASTER_ID}" ]; then
    echo "Found target master ${TARGET_MASTER_ID} that needs a replica."
    echo "Sending CLUSTER REPLICATE command..."

    if valkey-cli ${AUTH_OPTION} ${TLS_OPTION} -h localhost -p {{ .Values.service.port }} cluster replicate "${TARGET_MASTER_ID}"; then
      echo "Successfully configured as a replica for ${TARGET_MASTER_ID}."
    else
      echo "ERROR: Failed to replicate master ${TARGET_MASTER_ID}. Manual intervention required."
      exit 1
    fi
  else
    echo "WARNING: Could not find a master that needs a replica. Staying as a master with no slots. Attempting rebalance..."

    # Wait for cluster propagation before rebalancing
    PROPAGATION_ATTEMPTS=0
    MAX_PROPAGATION_ATTEMPTS=60
    while [ ${PROPAGATION_ATTEMPTS} -lt ${MAX_PROPAGATION_ATTEMPTS} ]; do
      CLUSTER_STATE=$(valkey-cli ${AUTH_OPTION} ${TLS_OPTION} -h localhost -p {{ .Values.service.port }} cluster info 2>/dev/null | grep "cluster_state:" | cut -d: -f2 | tr -d '\r\n')
      if [ "${CLUSTER_STATE}" = "ok" ]; then
        echo "Cluster state is OK. Proceeding with rebalance."
        break
      fi
      echo "Cluster state is ${CLUSTER_STATE}. Waiting for propagation... (${PROPAGATION_ATTEMPTS}/${MAX_PROPAGATION_ATTEMPTS})"
      PROPAGATION_ATTEMPTS=$((PROPAGATION_ATTEMPTS + 1))
      sleep 5
    done

    valkey-cli ${AUTH_OPTION} ${TLS_OPTION} --cluster rebalance "${HEALTHY_NODE}:{{ .Values.service.port }}" --cluster-use-empty-masters --cluster-yes || true
  fi
  exit 0
fi

echo "No healthy cluster found. Proceeding with initial creation logic."
if [ "${ORDINAL}" = "0" ]; then
  echo "This is the primary-0 node, creating a new cluster..."
  NODES=""
  for i in $(seq 0 $((CLUSTER_NODE_COUNT - 1))); do
    NODE_HOST="{{ include "valkey.fullname" . }}-${i}.${HEADLESS_SVC}.${NAMESPACE}.svc.${CLUSTER_DOMAIN}"
    until valkey-cli ${AUTH_OPTION} ${TLS_OPTION} -h "${NODE_HOST}" -p {{ .Values.service.port }} ping 2>/dev/null | grep -q "PONG"; do
      echo "Waiting for ${NODE_HOST} to be ready..."
      sleep 2
    done
    NODES="${NODES} ${NODE_HOST}:{{ .Values.service.port }}"
  done
  sleep 10

  echo "Creating cluster with nodes: ${NODES}"
  echo "yes" | valkey-cli ${AUTH_OPTION} ${TLS_OPTION} --cluster create ${NODES} --cluster-replicas "${REPLICAS_PER_SHARD}"
  echo "Cluster created successfully."
else
  echo "Waiting for pod-0 to initialize the cluster..."
  PRIMARY_HOST="{{ include "valkey.fullname" . }}-0.${HEADLESS_SVC}.${NAMESPACE}.svc.${CLUSTER_DOMAIN}"
  until valkey-cli ${AUTH_OPTION} ${TLS_OPTION} -h "${PRIMARY_HOST}" -p {{ .Values.service.port }} cluster info 2>/dev/null | grep -q "cluster_state:ok"; do
    echo "Waiting for cluster to be initialized by pod-0..."
    sleep 5
  done
  echo "Cluster is initialized. My role has been assigned by the creator."
fi

exit 0
