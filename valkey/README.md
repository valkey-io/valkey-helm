# valkey

![Version: 0.11.0](https://img.shields.io/badge/Version-0.11.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 9.1.1](https://img.shields.io/badge/AppVersion-9.1.1-informational?style=flat-square)

A Helm chart for Kubernetes

**Homepage:** <https://valkey.io/valkey-helm/>

## Maintainers

| Name | Url |
| ---- | --- |
| raven | [https://github.com/mk-raven] |
| sgissi | [https://github.com/sgissi] |
| Bloodraven21 | [https://github.com/Bloodraven21] |
## Source Code

* <https://github.com/valkey-io/valkey-helm.git>
* <https://valkey.io>

## Deployment Modes

### Standalone Mode (Default)

Deploy a single Valkey instance:

```bash
helm install valkey valkey/valkey
```

**Services:**

* `valkey`: Master/read-write service

### Replication Mode

Deploy Valkey with master-replica architecture for read scaling and data redundancy:

```bash
helm install valkey valkey/valkey --set replica.enabled=true --set replica.persistence.size=5Gi
```

**IMPORTANT**

**Services:**

* `valkey`: Master/write service
* `valkey-read`: Read service (load-balances across all pods) - optional
* `valkey-headless`: Headless service for pod discovery

**Write Safety Configuration:**

Ensure data durability by requiring a minimum number of replicas to be in sync before accepting writes:

```yaml
replica:
  minReplicasToWrite: 1  # Require at least 1 replica
  minReplicasMaxLag: 10  # Max 10 seconds replication lag
```

If fewer than `minReplicasToWrite` replicas are available, the master will reject write operations.

### High Availability Mode (Sentinel)

Replication mode alone does not recover from a master failure: the master is always pod-0 and a client keeps writing to it until an operator intervenes.
Enabling Sentinel creates a separate StatefulSet with three Sentinel pods by default.
The Sentinels monitor each other and the Valkey nodes, and promote a replica automatically when the master stops responding.

```bash
helm install valkey valkey/valkey -f examples/ha-sentinel.yaml
```

Sentinel needs at least three instances to form a quorum, independently of the Valkey pod count.
Valkey still needs at least one replica to provide a failover target.
See [examples/ha-sentinel.yaml](examples/ha-sentinel.yaml) for a complete values file.

Spread Sentinel pods across failure domains so one node or zone cannot remove the quorum.
The existing global `topologySpreadConstraints` value applies to both StatefulSets, and a selector for the Sentinel component limits the rule to Sentinel pods:

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app.kubernetes.io/component: sentinel
```

**Services:**

* `valkey`: load balances across all pods, the master can be any of them
* `valkey-sentinel`: Sentinel endpoints, used by clients to resolve the current master
* `valkey-headless`: headless service for Valkey pod discovery
* `valkey-sentinel-headless`: headless service for Sentinel peer discovery

**Connecting:**

Because the master moves, clients must ask Sentinel for its address instead of connecting to a fixed pod.
Most client libraries do this for you:

```python
from valkey.sentinel import Sentinel

sentinel = Sentinel([("valkey-sentinel", 26379)], password="...")
master = sentinel.master_for("mymaster")
master.set("key", "value")
```

Writes sent to the `valkey` service directly may land on a replica and fail with `-READONLY`.

**Authentication:**

Set `replica.sentinel.password` to a credential used only for the Sentinel endpoint, even when Valkey authentication is disabled.
With `auth.usersExistingSecret`, store that credential under `replica.sentinel.passwordKey` (default: `sentinel`) instead.
Valkey user passwords are deliberately not accepted by Sentinel, so restrictions on application ACL users cannot be bypassed through Sentinel commands.
Sentinel reaches the Valkey nodes as `replica.sentinel.monitorUser`, which defaults to `replica.replicationUser`.
That user must be allowed to promote a replica, otherwise every failover aborts with `-failover-abort-slave-timeout`.
The minimum permissions are:

```text
~* &* +multi +exec +ping +info +role +subscribe +publish +slaveof +replicaof
+config|rewrite +client|setname +client|kill +script|kill +psync +replconf
```

Sentinel can be enabled on an existing replication release without changing the Valkey StatefulSet's immutable fields.
Changing `replica.sentinel.persistence.enabled` later changes the Sentinel StatefulSet's `volumeClaimTemplates` and therefore requires recreating that StatefulSet.

**Credentials on disk:**

Valkey needs the replication password in plain text in its configuration, and `CONFIG REWRITE` writes it back on every failover even if the chart does not.
The configuration therefore lives on a memory backed `emptyDir` rather than on the data volume, so no credential is written to persistent storage.
The ACL file is hashed and also memory backed, and the Sentinel state is memory backed for the same reason, since Sentinel rewrites `auth-pass` and `sentinel-pass` into `sentinel.conf`.
Only the RDB or AOF and the init log stay on the data volume.

Enabling `replica.sentinel.persistence` opts out of this and puts `sentinel.conf`, credentials included, on a PersistentVolume.
It is off by default and not needed, because each Sentinel rediscovers the current master on startup.

**Failover behaviour:**

A master that stops responding for `replica.sentinel.downAfterMilliseconds` is replaced within a few seconds.
When a master pod is terminated by a rolling update, its `preStop` hook asks Sentinel to promote a replica first, so the failover happens before the pod goes away rather than after.
The replication topology survives a full restart of the StatefulSet: each pod asks Sentinel for the current master instead of assuming it is pod-0.

On a cold start the Sentinels are restarting too, and a Sentinel cannot name a master until a Valkey node is up, so waiting for one would leave both halves waiting for each other.
Each pod therefore mirrors the current master onto its data volume, as a host and a port with no credential in it, every `replica.sentinel.masterRecordRefreshSeconds`.
A pod that finds no Sentinel first asks the other Valkey nodes whether one of them is already up as the primary, and follows that answer if it gets one.
A node that is running outranks the record, both because a pod that was down across a failover still has its own name in its record, which would bring it back writable next to the node that was promoted, and because the record may name a node that has since been demoted.
Only when nothing answers does the record decide, which is what puts nodes on the network for the Sentinels to find.
A pod with neither a Sentinel, nor a running node, nor a record still refuses to start rather than guess.

The record is read from the config file Valkey rewrites when Sentinel changes a pod's role, so it needs no credentials.
A rewrite empties that file before filling it again, and a check landing in between sees no `replicaof` line, which is indistinguishable from a promotion.
A pod naming itself as the master therefore has to see that on two consecutive checks, while a pod that finds a master to follow records it on the first, since a partial read can drop a `replicaof` line but cannot invent one.
The record is one interval behind a demotion and two behind a promotion, one second each by default.

A promotion followed inside that window by the loss of every pod at once no longer hands writes back to the demoted node, because that node recorded its demotion on the first check.
What can still happen is that a pod which was down during a failover comes back following a node that has since been demoted, so it replicates through that node rather than from the primary.
Agreeing on a primary when no node can be reached is a consensus problem rather than a record keeping one, and this chart does not solve it.

Sentinel cannot repair that on its own, because it only learns which nodes are replicas by asking the primary, and a node replicating from a replica is not in that answer.
Each Sentinel therefore checks every `replica.sentinel.orphanCheckSeconds` for a node that is replicating from something other than the current primary and that Sentinel does not list, and points it back at the primary.
It only touches nodes Sentinel cannot see, which are exactly the ones Sentinel is not reconfiguring itself, and it stands down entirely while the primary is not plainly up.
A node that answers as a primary is left alone and logged rather than demoted.

### HAProxy Front-End

Sentinel requires a Sentinel-aware client.
When a client library does not support it, enable HAProxy to get a plain connection endpoint that always points at the current master:

```bash
helm install valkey valkey/valkey -f examples/ha-sentinel.yaml --set haproxy.enabled=true
```

HAProxy health checks every Valkey node with `INFO replication` and forwards the write port only to the node that answers `role:master`.
The health check is the failover mechanism, so no sidecar, no runtime package installation and no admin socket are involved.

**Services:**

* `valkey-haproxy:6379`: reads and writes, always routed to the current master
* `valkey-haproxy:6380`: reads, load balanced across all healthy nodes

**Labels:**

The HAProxy pods are labelled `app.kubernetes.io/name: valkey-haproxy`, not `valkey`.
The Valkey PodDisruptionBudget and the headless and Sentinel services select on the name and instance without a component, so sharing the Valkey name would put the proxy pods behind all of them: the budget would count six pods instead of three, and the headless service would resolve to proxy addresses.
Select the proxy pods with `app.kubernetes.io/name=valkey-haproxy` or `app.kubernetes.io/component=haproxy`.

**Failover behaviour:**

A failover has two steps, and HAProxy only covers the second one.
Sentinel first has to notice the failure (`replica.sentinel.downAfterMilliseconds`) and promote a replica; HAProxy then needs up to `haproxy.config.checkInterval` to see the new master in its health check.
End to end that is the sum of both, not `checkInterval` alone.
Clients see connection errors in the meantime and must reconnect, which is what a Sentinel-aware client would also do.
A short `-READONLY` window is still possible while a recovered old master is being demoted by Sentinel.

**Authentication:**

HAProxy authenticates its health check as `haproxy.checkUser`, which defaults to the `default` user and needs `+info` and `+ping`.
The password is passed to HAProxy as an environment variable read from the existing secret, so it never lands in a ConfigMap.

**TLS:**

With `tls.enabled`, `haproxy.tls.mode` decides what clients speak to HAProxy.

`passthrough` (the default) forwards the encrypted stream untouched, so the client completes the TLS handshake with the Valkey node itself and the connection stays encrypted end to end.
Clients connect with TLS exactly as they would to Valkey directly.
Because they connect to the HAProxy service name, the server certificate must also be valid for it, so add a SAN such as `valkey-haproxy.<namespace>.svc.<clusterDomain>` next to the pod names.

`bridge` is for clients that cannot do TLS at all: they connect in plaintext and HAProxy speaks TLS to the nodes on their behalf.
The client leg is then unencrypted, so only use it where that is acceptable.

In both modes HAProxy health checks the nodes over TLS and validates their certificates against `tls.caPublicKey`.
Set `haproxy.tls.verify: none` if the certificates do not cover the pod DNS names.

**Client certificates:**

With `tls.requireClientCertificate`, the nodes ask for a certificate on every connection, so HAProxy needs one of its own to health check them.
HAProxy reads a certificate and its private key from a single file, so the separate `tls.serverPublicKey` and `tls.serverKey` entries cannot serve as one.
Naming the key after the certificate, as `client.pem.key`, does not work either: that fallback is for `bind` lines, not for the backend `crt` used here.

Add a third entry to `tls.existingSecret` holding the certificate and its key concatenated, and name it in `haproxy.tls.clientCertFile`:

```bash
# concatenate the client certificate and its key into one PEM
cat client.crt client.key > client.pem

kubectl create secret generic valkey-tls \
  --from-file=ca.crt \
  --from-file=server.crt \
  --from-file=server.key \
  --from-file=client.pem
```

```yaml
tls:
  enabled: true
  existingSecret: valkey-tls
  requireClientCertificate: true
haproxy:
  tls:
    clientCertFile: client.pem
```

The same certificate is presented to every node, so it needs no SAN of its own, only a signature from `tls.caPublicKey`.
Leaving `haproxy.tls.clientCertFile` empty fails the install rather than starting a proxy whose health checks are refused by every node.

## Cluster Mode

This chart does not and will not support **Valkey cluster** mode. Managing a clustered topology is fundamentally different from standalone or replicated deployments, and the operational requirements go well beyond what this chart is designed to handle.

For cluster mode, a separate chart is being developed that uses the valkey-operator to deploy and manage clusters. The operator must be installed first.

To follow progress or get involved, see the [weekly meeting wiki](https://github.com/valkey-io/valkey-operator/wiki/Weekly-meeting).

## Storage

### Standalone Storage

Persistence is optional. By default, data is stored in an ephemeral volume and lost on pod restart.

**Enable persistent storage:**

```yaml
dataStorage:
  enabled: true
  requestedSize: 10Gi
  className: "fast-ssd"  # Optional
```

**Use existing PVC:**

```yaml
dataStorage:
  enabled: true
  persistentVolumeClaimName: "my-existing-pvc"
```

### Replication Storage

Persistent storage is **mandatory** in replication mode. Without it, the primary might come up with an empty dataset after a restart, all replicas will synchronize with the empty primary and lose their data. See [Valkey Replication Safety](https://valkey.io/topics/replication/#safety-of-replication-when-primary-has-persistence-turned-off) for details.

```yaml
replica:
  enabled: true
  persistence:
    size: 10Gi  # Required
    storageClass: "fast-ssd"  # Optional
```

## Authentication

This chart supports ACL-based authentication for Valkey.

**⚠️ IMPORTANT:** When authentication is enabled, the `default` user **MUST** be defined in either `auth.aclUsers` or `auth.aclConfig`. Without a default user, anyone can access the database without credentials.

### Existing Secret (recommended)

Reference an existing Kubernetes secret containing user passwords:

```yaml
auth:
  enabled: true
  usersExistingSecret: "my-valkey-users"
  aclUsers:
    default:
      permissions: "~* &* +@all"
      # Password will be read from secret key "default" (defaults to username)
    readonly:
      permissions: "~* -@all +@read +ping +info"
      passwordKey: "readonly-pwd"  # Use custom secret key name
```

### Inline Passwords

Define users directly in your values file with inline passwords:

```yaml
auth:
  enabled: true
  aclUsers:
    default:
      permissions: "~* &* +@all"
      password: "default-password"
    readonly:
      permissions: "~* -@all +@read +ping +info"
      password: "readonly-password"
```

**Note:**

* If `usersExistingSecret` is defined, passwords from the secret will take precedence over inline passwords.

### Custom ACL Configuration

You can also provide raw ACL configuration that will be appended after any generated users:

```yaml
auth:
  enabled: true
  aclConfig: |
    user default on >defaultpassword ~* &* +@all
    user guest on nopass ~public:* +@read
```

### Replication with Authentication

When using ACL authentication in replication mode, replicas need credentials to authenticate to the master:

```yaml
auth:
  enabled: true
  usersExistingSecret: "my-valkey-users"
  aclUsers:
    default:
      permissions: "~* &* +@all"
    replication-user:
      permissions: "+psync +replconf +ping"

replica:
  enabled: true
  replicas: 2
  replicationUser: "replication-user"  # Must be defined in auth.aclUsers
```

**Important Notes:**

* `replica.replicationUser` specifies which ACL user replicas use to authenticate
* This user MUST be defined in `auth.aclUsers` with appropriate permissions
* Minimum permissions: `+psync +replconf +ping`

## Metrics

This chart supports Prometheus metrics collection using the [Redis exporter](https://github.com/oliver006/redis_exporter).

Enable the metrics exporter sidecar:

```yaml
metrics:
  enabled: true
```

### Prometheus Operator discovery

Automated Prometheus discovery using the Prometheus Operator ServiceMonitor:

```yaml
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
```

## PodDisruptionBudget

A PodDisruptionBudget helps keep enough read-replicas available during voluntary disruptions like node drains or rolling updates.

**Enable PDB (only works in replicated mode):**

```yaml
podDisruptionBudget:
  enabled: true
  maxUnavailable: 1  # Allow at most 1 pod to be unavailable
```

**Or use minAvailable to guarantee a specific number of replicas:**

```yaml
podDisruptionBudget:
  enabled: true
  minAvailable: 2  # Always keep at least 2 replicas running
```

## TLS

This chart supports TLS encryption for Valkey connections.

First create a secret containing the certificate public and private keys plus CA public key:

```shell
kubectl create secret generic valkey-tls-secret --from-file=server.crt --from-file=server.key --from-file=ca.crt
```

Enable TLS and provide the name of the secret created above:

```yaml
tls:
  enabled: true
  existingSecret: "valkey-tls-secret"
```

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| global.imageRegistry | string | '' |  |
| global.imagePullSecrets | list | `[]` |  |
| affinity | object | `{}` |  |
| auth.aclConfig | string | `""` |  |
| auth.aclUsers | object | `{}` | |
| auth.enabled | bool | `false` |  |
| auth.usersExistingSecret | string | `""` | |
| dataStorage.accessModes[0] | string | `"ReadWriteOnce"` |  |
| dataStorage.annotations | object | `{}` |  |
| dataStorage.className | string | `""` |  |
| dataStorage.enabled | bool | `false` |  |
| dataStorage.keepPvc | bool | `false` |  |
| dataStorage.labels | object | `{}` |  |
| dataStorage.persistentVolumeClaimName | string | `""` |  |
| dataStorage.requestedSize | string | `""` |  |
| dataStorage.subPath | string | `""` |  |
| dataStorage.volumeName | string | `"valkey-data"` |  |
| dataStorage.hostPath | string | `""` |  |
| deploymentStrategy | string | `"RollingUpdate"` |  |
| env | object | `{}` |  |
| extraSecretValkeyConfigs | bool | `false` |  |
| extraVolumes | list | `[]` |  |
| extraVolumeMounts | list | `[]` |  |
| extraValkeyConfigs | list | `[]` |  |
| extraValkeySecrets | list | `[]` |  |
| fullnameOverride | string | `""` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.registry | string | `""` |  |
| image.repository | string | `"docker.io/valkey/valkey"` |  |
| image.tag | string | `""` |  |
| imagePullSecrets | list | `[]` |  |
| initResources | object | `{}` |  |
| livenessProbe.customProbe | object | `{}` | Full probe spec to replace the default valkey-cli ping handler and timing |
| livenessProbe.enabled | bool | `true` |  |
| livenessProbe.failureThreshold | int | `3` |  |
| livenessProbe.initialDelaySeconds | int | `0` |  |
| livenessProbe.periodSeconds | int | `10` |  |
| livenessProbe.timeoutSeconds | int | `1` |  |
| metrics.enabled | bool | `false` |  |
| metrics.exporter.args | list | `[]` |  |
| metrics.exporter.command | list | `[]` |  |
| metrics.exporter.extraEnvs | object | `{}` |  |
| metrics.exporter.extraVolumeMounts | list | `[]` |  |
| metrics.exporter.image.pullPolicy | string | `"IfNotPresent"` |  |
| metrics.exporter.image.repository | string | `"ghcr.io/oliver006/redis_exporter"` |  |
| metrics.exporter.image.tag | string | `"v1.79.0"` |  |
| metrics.exporter.port | int | `9121` |  |
| metrics.exporter.resources | object | `{}` |  |
| metrics.exporter.securityContext | object | `{}` |  |
| metrics.podMonitor.additionalLabels | object | `{}` |  |
| metrics.podMonitor.annotations | object | `{}` |  |
| metrics.podMonitor.enabled | bool | `false` |  |
| metrics.podMonitor.extraLabels | object | `{}` |  |
| metrics.podMonitor.honorLabels | bool | `false` |  |
| metrics.podMonitor.interval | string | `"30s"` |  |
| metrics.podMonitor.metricRelabelings | list | `[]` |  |
| metrics.podMonitor.podTargetLabels | list | `[]` |  |
| metrics.podMonitor.port | string | `"metrics"` |  |
| metrics.podMonitor.relabelings | list | `[]` |  |
| metrics.podMonitor.sampleLimit | bool | `false` |  |
| metrics.podMonitor.scrapeTimeout | string | `""` |  |
| metrics.podMonitor.targetLimit | bool | `false` |  |
| metrics.prometheusRule.enabled | bool | `false` |  |
| metrics.prometheusRule.extraAnnotations | object | `{}` |  |
| metrics.prometheusRule.extraLabels | object | `{}` |  |
| metrics.prometheusRule.rules | list | `[]` |  |
| metrics.service.annotations | object | `{}` |  |
| metrics.service.enabled | bool | `true` |  |
| metrics.service.extraLabels | object | `{}` |  |
| metrics.service.ports.http | int | `9121` |  |
| metrics.service.type | string | `"ClusterIP"` |  |
| metrics.service.appProtocol | string | `""` |  |
| metrics.serviceMonitor.additionalLabels | object | `{}` |  |
| metrics.serviceMonitor.annotations | object | `{}` |  |
| metrics.serviceMonitor.enabled | bool | `false` |  |
| metrics.serviceMonitor.extraLabels | object | `{}` |  |
| metrics.serviceMonitor.honorLabels | bool | `false` |  |
| metrics.serviceMonitor.interval | string | `"30s"` |  |
| metrics.serviceMonitor.metricRelabelings | list | `[]` |  |
| metrics.serviceMonitor.podTargetLabels | list | `[]` |  |
| metrics.serviceMonitor.port | string | `"metrics"` |  |
| metrics.serviceMonitor.relabelings | list | `[]` |  |
| metrics.serviceMonitor.sampleLimit | bool | `false` |  |
| metrics.serviceMonitor.scrapeTimeout | string | `""` |  |
| metrics.serviceMonitor.targetLimit | bool | `false` |  |
| nameOverride | string | `""` |  |
| networkPolicy | object | `{}` |  |
| nodeSelector | object | `{}` |  |
| podAnnotations | object | `{}` |  |
| podLabels | object | `{}` |  |
| commonLabels | object | `{}` |  |
| podDisruptionBudget.enabled | bool | `false` |  |
| podDisruptionBudget.minAvailable | int or string | `null` | Minimum pods available during disruptions |
| podDisruptionBudget.maxUnavailable | int or string | `1` | Maximum pods unavailable during disruptions |
| podDisruptionBudget.unhealthyPodEvictionPolicy | string | `null` | Policy for evicting unhealthy pods |
| podSecurityContext.fsGroup | int | `1000` |  |
| podSecurityContext.runAsGroup | int | `1000` |  |
| podSecurityContext.runAsUser | int | `1000` |  |
| priorityClassName | string | `""` |  |
| runtimeClassName | string | `""` | RuntimeClassName for the pods (e.g. `gvisor`, `kata-containers`); empty uses the cluster default runtime |
| readinessProbe.customProbe | object | `{}` | Full probe spec to replace the default valkey-cli ping handler and timing |
| readinessProbe.enabled | bool | `false` | Opt-in; the Valkey container had no readiness probe before |
| readinessProbe.failureThreshold | int | `3` |  |
| readinessProbe.initialDelaySeconds | int | `0` |  |
| readinessProbe.periodSeconds | int | `10` |  |
| readinessProbe.successThreshold | int | `1` |  |
| readinessProbe.timeoutSeconds | int | `1` |  |
| replica.enabled | bool | `false` |  |
| replica.replicas | int | `2` |  |
| replica.replicationUser | string | `"default"` |  |
| replica.disklessSync | bool | `false` |  |
| replica.minReplicasToWrite | int | `0` |  |
| replica.minReplicasMaxLag | int | `10` |  |
| replica.service.enabled | bool | `"true"` |  |
| replica.service.type | string | `"ClusterIP"` |  |
| replica.service.port | int | `6379` |  |
| replica.service.annotations | object | `{}` |  |
| replica.service.nodePort | int | `0` |  |
| replica.service.clusterIP | string | `""` |  |
| replica.service.appProtocol | string | `""` |  |
| replica.service.loadBalancerClass | string | `""` |  |
| replica.persistence. |  | `""` |  |
| replica.persistence.size | string | `""` | Required if replica is enabled |
| replica.persistence.storageClass | string | `""` |  |
| replica.persistence.accessModes | list | `""` |  |
| replica.sentinel.enabled | bool | `false` | Run Valkey Sentinel for automatic failover |
| replica.sentinel.replicas | int | `3` | Number of independently deployed Sentinel pods |
| replica.sentinel.port | int | `26379` |  |
| replica.sentinel.masterSet | string | `"mymaster"` |  |
| replica.sentinel.masterRecordRefreshSeconds | int | `1` | How often the cold-start topology record is checked against the running config |
| replica.sentinel.quorum | int | `2` | Sentinels that must agree before a failover starts |
| replica.sentinel.downAfterMilliseconds | int | `5000` |  |
| replica.sentinel.failoverTimeout | int | `60000` |  |
| replica.sentinel.parallelSyncs | int | `1` |  |
| replica.sentinel.monitorUser | string | `""` | Defaults to replica.replicationUser |
| replica.sentinel.orphanCheckSeconds | int | `30` | How often each Sentinel looks for a node replicating from something it cannot see |
| replica.sentinel.password | string | `""` | Dedicated Sentinel ACL password; required with Sentinel unless supplied by auth.usersExistingSecret |
| replica.sentinel.passwordKey | string | `"sentinel"` | Key containing the Sentinel password in auth.usersExistingSecret |
| replica.sentinel.preStopFailover | bool | `true` | Fail over before a master pod is terminated |
| replica.sentinel.preStopFailoverTimeoutSeconds | int | `20` |  |
| replica.sentinel.startupTimeoutSeconds | int | `60` |  |
| replica.sentinel.extraConfig | string | `""` | Raw lines appended to sentinel.conf |
| replica.sentinel.resources | object | `{}` |  |
| replica.sentinel.securityContext | object | `{}` | Defaults to securityContext |
| replica.sentinel.service.enabled | bool | `true` |  |
| replica.sentinel.service.type | string | `"ClusterIP"` |  |
| replica.sentinel.service.port | int | `26379` |  |
| replica.sentinel.service.annotations | object | `{}` |  |
| replica.sentinel.persistence.enabled | bool | `false` |  |
| replica.sentinel.persistence.size | string | `"100Mi"` |  |
| replica.sentinel.persistence.storageClass | string | `""` |  |
| replica.sentinel.persistentVolumeClaimRetentionPolicy | object | `{}` | PVC retention policy for the Sentinel StatefulSet |
| haproxy.enabled | bool | `false` | Route non Sentinel-aware clients to the current master |
| haproxy.replicas | int | `3` |  |
| haproxy.image.registry | string | `"docker.io"` |  |
| haproxy.image.repository | string | `"haproxy"` |  |
| haproxy.image.tag | string | `"3.2-alpine"` | HAProxy 3.1 or newer is required |
| haproxy.image.pullPolicy | string | `"IfNotPresent"` |  |
| haproxy.checkUser | string | `""` | Defaults to the 'default' user |
| haproxy.service.type | string | `"ClusterIP"` |  |
| haproxy.service.port | int | `6379` | Write port, follows the master |
| haproxy.service.readPort | int | `6380` | Read port, load balanced |
| haproxy.service.annotations | object | `{}` |  |
| haproxy.config.maxconn | int | `4096` |  |
| haproxy.config.checkInterval | string | `"2s"` | Time for HAProxy to notice a new master, on top of Sentinel's own detection |
| haproxy.config.checkTimeout | string | `"5s"` |  |
| haproxy.config.healthPort | int | `8404` | Serves /healthz for the Kubernetes probes, not published |
| haproxy.config.readBalance | string | `"roundrobin"` |  |
| haproxy.config.timeout.connect | string | `"5s"` |  |
| haproxy.config.timeout.client | string | `"1m"` |  |
| haproxy.config.timeout.server | string | `"1m"` |  |
| haproxy.config.timeout.tunnel | string | `"0s"` | Keeps pub/sub connections open |
| haproxy.tls.mode | string | `"passthrough"` | passthrough keeps TLS end to end, bridge accepts plaintext clients |
| haproxy.tls.verify | string | `"required"` | Certificate validation towards the nodes |
| haproxy.tls.clientCertFile | string | `""` | Combined cert+key, required with tls.requireClientCertificate |
| haproxy.podDisruptionBudget.enabled | bool | `false` | Keep HAProxy replicas available across node drains |
| haproxy.podDisruptionBudget.minAvailable | int | `null` | Takes precedence over maxUnavailable |
| haproxy.podDisruptionBudget.maxUnavailable | int | `1` |  |
| haproxy.podDisruptionBudget.unhealthyPodEvictionPolicy | string | `""` |  |
| haproxy.resources | object | `{}` |  |
| haproxy.podSecurityContext | object | see values.yaml |  |
| haproxy.securityContext | object | see values.yaml |  |
| haproxy.extraInitContainers | list | `[]` |  |
| haproxy.extraVolumes | list | `[]` |  |
| haproxy.extraVolumeMounts | list | `[]` |  |
| resources | object | `{}` |  |
| securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| securityContext.readOnlyRootFilesystem | bool | `true` |  |
| securityContext.runAsNonRoot | bool | `true` |  |
| securityContext.runAsUser | int | `1000` |  |
| service.annotations | object | `{}` |  |
| service.nodePort | int | `0` |  |
| service.port | int | `6379` |  |
| service.type | string | `"ClusterIP"` |  |
| service.appProtocol | string | `""` |  |
| service.loadBalancerClass | string | `""` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.automount | bool | `false` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| startupProbe.customProbe | object | `{}` | Full probe spec to replace the default valkey-cli ping handler and timing |
| startupProbe.enabled | bool | `true` |  |
| startupProbe.failureThreshold | int | `3` |  |
| startupProbe.initialDelaySeconds | int | `0` |  |
| startupProbe.periodSeconds | int | `10` |  |
| startupProbe.timeoutSeconds | int | `1` |  |
| tls.caPublicKey | string | `"ca.crt"` |  |
| tls.dhParamKey | string | `""` |  |
| tls.enabled | bool | `false` |  |
| tls.existingSecret | string | `""` |  |
| tls.requireClientCertificate | bool | `false` |  |
| tls.serverKey | string | `"server.key"` |  |
| tls.serverPublicKey | string | `"server.crt"` |  |
| tolerations | list | `[]` |  |
| topologySpreadConstraints | list | `[]` |  |
| valkeyConfig | string | `""` |  |
| valkeyLogLevel | string | `"notice"` |  |
| workloadAnnotations | object | `{}` |  |
