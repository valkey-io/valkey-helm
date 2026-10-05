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

## Upgrading

Breaking changes and the steps to migrate an existing release are listed in [UPGRADE.md](UPGRADE.md).

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
helm install valkey valkey/valkey --set replica.enabled=true --set persistence.enabled=true --set persistence.size=5Gi
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
The Sentinel pods are scheduled with their own `sentinel.affinity`, `topologySpreadConstraints`, `nodeSelector` and `tolerations`, and labelled with their own `sentinel.podLabels` and `podAnnotations`.
The top level `affinity`, `topologySpreadConstraints`, `podLabels` and `podAnnotations` apply to the Valkey pods only, because rules written for the Valkey pods select the Valkey pods' labels; the HAProxy pods likewise take `haproxy.podLabels` and `haproxy.podAnnotations`.
`nodeSelector` and `tolerations` fall back to the top level values when the Sentinel ones are unset (`null`, the default); set them to `{}` / `[]` to schedule the Sentinels without any. The HAProxy values work the same way.

```yaml
sentinel:
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels:
          app.kubernetes.io/instance: valkey
          app.kubernetes.io/component: sentinel
  # Keep a Sentinel majority through node drains
  podDisruptionBudget:
    enabled: true
    maxUnavailable: 1
```

The Valkey PodDisruptionBudget (`podDisruptionBudget`) does not cover the Sentinel pods; `sentinel.podDisruptionBudget` creates a separate one for them.

**Services:**

* `valkey`: load balances across all pods, the master can be any of them, so it is labelled `app.kubernetes.io/component: nodes` rather than `primary` and is not a write endpoint
* `valkey-sentinel`: Sentinel endpoints, used by clients to resolve the current master
* `valkey-headless`: headless service for Valkey pod discovery
* `valkey-sentinel-hl`: headless service for Sentinel peer discovery

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

Set `sentinel.password` to a credential used only for the Sentinel endpoint, even when Valkey authentication is disabled, or point `sentinel.existingSecret` at a Secret holding it under `sentinel.passwordKey` (default: `sentinel`).
Clients, the Sentinels among themselves and the Valkey pods' scripts use it; the Valkey server never does.
Valkey user passwords are deliberately not accepted by Sentinel, so restrictions on application ACL users cannot be bypassed through Sentinel commands.
Sentinel reaches the Valkey nodes as `sentinel.monitorUser`, which defaults to `replica.replicationUser`.
That user must be allowed to promote a replica, otherwise every failover aborts with `-failover-abort-slave-timeout`.
A starting pod asks the other nodes which of them is the primary as the same user, rather than as `replica.replicationUser`, whose documented minimum cannot run `INFO`.
The minimum permissions are:

```text
~* &* +multi +exec +ping +info +role +subscribe +publish +slaveof +replicaof
+config|rewrite +client|setname +client|kill +client|pause +client|unpause
+script|kill +psync +replconf
```

`+client|pause` and `+client|unpause` are for the `preStop` hook described below; without them failovers still work, but the writes the old master acknowledges during a graceful failover are lost.

Sentinel can be enabled on an existing replication release without changing the Valkey StatefulSet's immutable fields.
Changing `sentinel.persistence.enabled` later changes the Sentinel StatefulSet's `volumeClaimTemplates` and therefore requires recreating that StatefulSet.

**Credentials on disk:**

Valkey needs the replication password in plain text in its configuration, and `CONFIG REWRITE` writes it back on every failover even if the chart does not.
The configuration therefore lives on a memory backed `emptyDir` rather than on the data volume, so no credential is written to persistent storage.
The ACL file holds only password hashes and sits next to it on the same volume, and the Sentinel state is memory backed for the same reason, since Sentinel rewrites `auth-pass` and `sentinel-pass` into `sentinel.conf`.
Only the RDB or AOF and the init log stay on the data volume.

Enabling `sentinel.persistence` opts out of this and puts `sentinel.conf`, credentials included, on a PersistentVolume.
It is off by default and not needed, because each Sentinel rediscovers the current master on startup.

**Failover behaviour:**

A master that stops responding for `sentinel.downAfterMilliseconds` is replaced within a few seconds.
When a master pod is terminated, by a rolling update or a node drain, its `preStop` hook hands over to a replica before the pod goes away:

1. It waits, for at most half of `sentinel.preStopFailoverTimeoutSeconds`, until a Sentinel sees every other pod as a healthy replica of this one. Sentinel only repoints the replicas it can reach when it promotes one, and a pod restarted a moment earlier is still marked down for several seconds after it is ready; one left behind can be promoted by a later failover, discarding every write made in between.
2. It pauses writes, so that the replica Sentinel promotes has every write this pod acknowledged.
3. It asks that Sentinel to fail over, then follows the new master and closes its client connections. Clients that wrote during the handover get a connection error and retry against the new master, instead of having their writes acknowledged and discarded.

A failover that is not planned, a crashed pod or a lost node, has none of this: the master's last writes before it went away can still be lost.
The replication topology survives a full restart of the StatefulSet: each pod asks Sentinel for the current master instead of assuming it is pod-0.

On a cold start the Sentinels are restarting too, and a Sentinel cannot name a master until a Valkey node is up, so waiting for one would leave both halves waiting for each other.
Each pod therefore mirrors the current master onto its data volume, as a host and a port with no credential in it, every `sentinel.masterRecordRefreshSeconds`.
A pod that finds no Sentinel first asks the other Valkey nodes whether one of them is already up as the primary, and follows that answer if it gets one.
A node that is running outranks the record, both because a pod that was down across a failover still has its own name in its record, which would bring it back writable next to the node that was promoted, and because the record may name a node that has since been demoted.
Only when nothing answers does the record decide, which is what puts nodes on the network for the Sentinels to find.
A pod with neither a Sentinel, nor a running node, nor a record waits up to `sentinel.initialTopologyWaitSeconds` for one of them and then refuses to start rather than guess.
That wait is what a first install spends: the Sentinels bootstrap a master once their own `sentinel.startupTimeoutSeconds` expires, and the pod is simply there to be told, so the chart refuses to render unless the wait is at least 30 seconds above it.

The record is read from the config file Valkey rewrites when Sentinel changes a pod's role, so it needs no credentials.
A rewrite empties that file before filling it again, and a check landing in between sees no `replicaof` line, which is indistinguishable from a promotion.
A pod naming itself as the master therefore has to see that on two consecutive checks, while a pod that finds a master to follow records it on the first, since a partial read can drop a `replicaof` line but cannot invent one.
The record is one interval behind a demotion and two behind a promotion, one second each by default.

A promotion followed inside that window by the loss of every pod at once no longer hands writes back to the demoted node, because that node recorded its demotion on the first check.
What can still happen is that a pod which was down during a failover comes back following a node that has since been demoted, so it replicates through that node rather than from the primary.
Agreeing on a primary when no node can be reached is a consensus problem rather than a record keeping one, and this chart does not solve it.

Sentinel cannot repair that on its own, because it only learns which nodes are replicas by asking the primary, and a node replicating from a replica is not in that answer.
Each Sentinel therefore checks every `sentinel.orphanCheckSeconds` for a node that is replicating from something other than the current primary and that Sentinel does not list, and points it back at the primary.
It only touches nodes Sentinel cannot see, which are exactly the ones Sentinel is not reconfiguring itself, and it stands down entirely while the primary is not plainly up.
A node that answers as a primary is left alone and logged rather than demoted.

### HAProxy Front-End

Sentinel requires a Sentinel-aware client.
When a client library does not support it, enable HAProxy to get a plain connection endpoint that always points at the current master:

```bash
helm install valkey valkey/valkey -f examples/ha-sentinel.yaml --set haproxy.enabled=true
```

HAProxy health checks every Valkey node with `INFO replication` and asks every Sentinel which node is the master.
It forwards the write port only to the node that answers `role:master` and that a majority of the Sentinels name as the master.
The health checks are the failover mechanism, so no sidecar, no runtime package installation and no admin socket are involved.

**Services:**

* `valkey-haproxy:6379`: reads and writes, always routed to the current master

There is no separate read endpoint, `valkey-read` already load balances across every pod.
It only drops a pod based on the pod's own probes, though, and the readiness probe is off by default.
A pod that stops answering therefore keeps receiving reads until the liveness probe restarts it, which takes up to `livenessProbe.periodSeconds` times `livenessProbe.failureThreshold`, 30 seconds by default.
If reads need to move off a failing pod faster than that, enable `readinessProbe` with a shorter period or a lower failure threshold.

**Labels:**

The HAProxy pods are labelled `app.kubernetes.io/name: valkey-haproxy`, not `valkey`.
The Valkey PodDisruptionBudget and the headless and Sentinel services select on the name and instance without a component, so sharing the Valkey name would put the proxy pods behind all of them: the budget would count six pods instead of three, and the headless service would resolve to proxy addresses.
Select the proxy pods with `app.kubernetes.io/name=valkey-haproxy` or `app.kubernetes.io/component=haproxy`.

**Failover behaviour:**

A failover has two steps, and HAProxy only covers the second one.
Sentinel first has to notice the failure (`sentinel.downAfterMilliseconds`) and promote a replica; HAProxy then needs up to `haproxy.config.checkInterval` to see the change in its health checks.
End to end that is the sum of both, not `checkInterval` alone.
Clients see connection errors in the meantime and must reconnect, which is what a Sentinel-aware client would also do.

HAProxy follows the Sentinels rather than `role:master` alone because an old master keeps answering `role:master` for several seconds after Sentinel has promoted a replica, and the writes it takes in that time are discarded when it resyncs.
The write port therefore also depends on the Sentinels: while a majority of them is unreachable, HAProxy closes new connections even if the master itself is healthy.

When the old master goes away on its own `preStop` hook, it closes its client connections as it hands over, so connections that are already open follow the new master too.

**Authentication:**

HAProxy authenticates its health check as `haproxy.checkUser`, which defaults to the `default` user and needs `+info` and `+ping`.
It authenticates to the Sentinels as the `sentinel` user, with the Sentinel password.
Both passwords are passed to HAProxy as environment variables read from their secrets, so they never land in a ConfigMap.

**TLS:**

With `tls.enabled`, HAProxy forwards the encrypted stream untouched and the client completes the TLS handshake with the Valkey node itself, so the connection stays encrypted end to end.
Clients connect with TLS exactly as they would to Valkey directly.
Because they connect to the HAProxy service name, the server certificate must also be valid for it, so add a SAN such as `valkey-haproxy.<namespace>.svc.<clusterDomain>` next to the pod names.

HAProxy never terminates a client's TLS connection.
Doing so would put one proxy certificate in front of every client, and on a node that maps a certificate to a user, every client would inherit that user's rights.
It follows that clients which cannot speak TLS cannot use this proxy against a TLS enabled cluster, because the nodes themselves listen on the TLS port only.

HAProxy does speak TLS for its own health checks, and `haproxy.tls.verify` decides how far it validates the nodes and the Sentinels.
Of `tls.existingSecret` it only mounts what those checks read, `tls.caPublicKey` and, when set, `haproxy.tls.clientCertFile`, so the Valkey server's private key never reaches the HAProxy pods.

`required`, the default, validates the certificate against `tls.caPublicKey` and checks that it covers the DNS name of the pod being checked.
That second part is what usually surprises people: HAProxy checks each pod separately, so a certificate issued for the service name alone fails, and every backend goes down with `Server presented an SSL certificate different from the configured one`.
Either add the pod names to the certificate, as `<release>-valkey-<index>.<release>-valkey-headless.<namespace>.svc.<clusterDomain>` for the nodes and `<release>-valkey-sentinel-<index>.<release>-valkey-sentinel-hl.<namespace>.svc.<clusterDomain>` for the Sentinels, or set `haproxy.tls.verify: none`, which keeps the health checks encrypted but stops validating what they are talking to.

**Client certificates:**

With `tls.requireClientCertificate`, the nodes and the Sentinels ask for a certificate on every connection, so HAProxy needs one of its own to health check them.
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

The same certificate is presented to every node and Sentinel, so it needs no SAN of its own, only a signature from `tls.caPublicKey`.
Leaving `haproxy.tls.clientCertFile` empty fails the install rather than starting a proxy whose health checks are refused by every node.

## Cluster Mode

This chart does not and will not support **Valkey cluster** mode. Managing a clustered topology is fundamentally different from standalone or replicated deployments, and the operational requirements go well beyond what this chart is designed to handle.

For cluster mode, a separate chart is being developed that uses the valkey-operator to deploy and manage clusters. The operator must be installed first.

To follow progress or get involved, see the [weekly meeting wiki](https://github.com/valkey-io/valkey-operator/wiki/Weekly-meeting).

## Storage

The `persistence` block configures the Valkey data directory (`/data`) in both modes.
The volume and claim names do not depend on these values: the standalone PVC is named `<fullname>`, and the replication PVCs `valkey-data-<statefulset>-<index>`.

### Standalone Storage

Persistence is optional. By default, data is stored in an ephemeral volume and lost on pod restart.

The standalone Deployment uses the `Recreate` strategy (`deploymentStrategy`): on an upgrade the old pod stops before the new one starts, so the data volume is never attached to two pods, at the cost of a short downtime.

**Enable persistent storage:**

```yaml
persistence:
  enabled: true
  size: 10Gi
  storageClass: "fast-ssd"  # Optional
```

**Use an existing PVC** (or `hostPath` for a hostPath volume):

```yaml
persistence:
  enabled: true
  existingClaim: "my-existing-pvc"
```

When more than one is set, `existingClaim` wins over `size`, which wins over `hostPath`.
`keepOnUninstall: true` keeps the chart created PVC on `helm uninstall`.

### Replication Storage

Persistent storage is **mandatory** in replication mode. Without it, the primary might come up with an empty dataset after a restart, all replicas will synchronize with the empty primary and lose their data. See [Valkey Replication Safety](https://valkey.io/topics/replication/#safety-of-replication-when-primary-has-persistence-turned-off) for details.

```yaml
replica:
  enabled: true
persistence:
  enabled: true
  size: 10Gi  # Required
  storageClass: "fast-ssd"  # Optional
```

Each pod gets its own PVC from the StatefulSet's `volumeClaimTemplates`.
`existingClaim`, `hostPath` and `keepOnUninstall` do not apply; to reuse existing volumes, create the claims as `valkey-data-<statefulset>-<index>` before installing.
Kubernetes does not allow changing `volumeClaimTemplates`, so `persistence.labels` and `persistence.annotations` only apply to new installs, and changing `accessModes` or `storageClass` later requires recreating the StatefulSet.

## Customizing Valkey

Each kind of customization has one value:

* `extraConfig`: raw lines appended to the generated `valkey.conf` (templated).
* `extraVolumes`: additional volumes for the Valkey pod, of any type (Secret, ConfigMap, ...). `extraVolumeMounts` mounts them into the Valkey container and `metrics.exporter.extraVolumeMounts` into the exporter; containers from `extraInitContainers` and `extraContainers` declare their own `volumeMounts`.
* `extraEnv`: additional environment variables for the Valkey container, as Kubernetes EnvVar entries (`metrics.exporter.extraEnv` for the exporter).

To load configuration from a Secret or ConfigMap, mount it and `include` it:

```yaml
extraVolumes:
  - name: extra-conf
    secret:
      secretName: my-valkey-conf
extraVolumeMounts:
  - name: extra-conf
    mountPath: /extra-conf
    readOnly: true
extraConfig: |
  include /extra-conf/valkey.conf
extraEnv:
  - name: MY_TOKEN
    valueFrom:
      secretKeyRef:
        name: my-secret
        key: token
```

Sentinel takes its own `sentinel.extraConfig`, appended to `sentinel.conf`.

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

The chart regenerates the ACL file from these values whenever a pod starts, so users added at runtime with `ACL SETUSER` last only until the next restart.
A user allowed to run `ACL SAVE` or `CONFIG REWRITE` can still rewrite the generated files while the pod runs (`+@all` includes both): give application users narrower permissions, e.g. `+@all -@admin`.

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
  replicas: 3  # Valkey pods, the master included
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
| affinity | object | `{}` | Valkey pods only, see sentinel.affinity |
| auth.aclConfig | string | `""` |  |
| auth.aclUsers | object | `{}` | |
| auth.enabled | bool | `false` |  |
| auth.usersExistingSecret | string | `""` | |
| deploymentStrategy | string | `"Recreate"` | Standalone Deployment strategy; RollingUpdate is only safe without persistence |
| extraConfig | string | `""` | Raw lines appended to valkey.conf; supports templating and `include` |
| extraContainers | list | `[]` | Additional containers in the Valkey pod |
| extraEnv | list | `[]` | Additional EnvVar entries for the Valkey container (value or valueFrom) |
| extraInitContainers | list | `[]` | Additional init containers in the Valkey pod |
| extraVolumes | list | `[]` | Additional volumes for the Valkey pod |
| extraVolumeMounts | list | `[]` | Mounts of extraVolumes into the Valkey container |
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
| metrics.exporter.extraEnv | list | `[]` | EnvVar entries; also overrides the REDIS_ADDR and REDIS_EXPORTER_TLS_* values the chart sets |
| metrics.exporter.extraVolumeMounts | list | `[]` | Mounts of extraVolumes into the exporter container |
| metrics.exporter.image.pullPolicy | string | `"IfNotPresent"` |  |
| metrics.exporter.image.repository | string | `"ghcr.io/oliver006/redis_exporter"` |  |
| metrics.exporter.image.tag | string | `"v1.88.0"` |  |
| metrics.exporter.port | int | `9121` |  |
| metrics.exporter.tlsServerName | string | `""` | Server name expected in the Valkey certificate with TLS, defaults to the service name |
| metrics.exporter.resources | object | `{}` |  |
| metrics.exporter.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true,"runAsNonRoot":true}` | Merged with user values; `null` drops them |
| metrics.podMonitor.annotations | object | `{}` |  |
| metrics.podMonitor.enabled | bool | `false` |  |
| metrics.podMonitor.labels | object | `{}` | Labels on the PodMonitor, e.g. for a Prometheus `podMonitorSelector` |
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
| metrics.prometheusRule.annotations | object | `{}` |  |
| metrics.prometheusRule.labels | object | `{}` |  |
| metrics.prometheusRule.rules | list | `[]` |  |
| metrics.service.annotations | object | `{}` |  |
| metrics.service.enabled | bool | `true` |  |
| metrics.service.labels | object | `{}` |  |
| metrics.service.ports.http | int | `9121` |  |
| metrics.service.type | string | `"ClusterIP"` |  |
| metrics.service.appProtocol | string | `""` |  |
| metrics.serviceMonitor.annotations | object | `{}` |  |
| metrics.serviceMonitor.enabled | bool | `false` |  |
| metrics.serviceMonitor.labels | object | `{}` | Labels on the ServiceMonitor, e.g. for a Prometheus `serviceMonitorSelector` |
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
| persistence.enabled | bool | `false` | Required in replication mode |
| persistence.size | string | `""` | PVC size (one per pod in replication) |
| persistence.storageClass | string | `""` |  |
| persistence.accessModes | list | `["ReadWriteOnce"]` |  |
| persistence.subPath | string | `""` | Subpath of the volume mounted as /data |
| persistence.labels | object | `{}` | PVC labels; replication: new installs only |
| persistence.annotations | object | `{}` | PVC annotations; replication: new installs only |
| persistence.existingClaim | string | `""` | Standalone only |
| persistence.hostPath | string | `""` | Standalone only |
| persistence.keepOnUninstall | bool | `false` | Standalone only |
| podAnnotations | object | `{}` | Valkey pods only, see sentinel.podAnnotations and haproxy.podAnnotations |
| podLabels | object | `{}` | Valkey pods only, see sentinel.podLabels and haproxy.podLabels |
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
| replica.replicas | int | `3` | Valkey pods, the master included; at least 1 (2 with Sentinel) |
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
| haproxy.enabled | bool | `false` | Route non Sentinel-aware clients to the current master |
| haproxy.replicas | int | `3` |  |
| haproxy.image.registry | string | `"docker.io"` |  |
| haproxy.image.repository | string | `"haproxy"` |  |
| haproxy.image.tag | string | `"3.2-alpine"` | HAProxy 3.1 or newer is required |
| haproxy.image.pullPolicy | string | `"IfNotPresent"` |  |
| haproxy.checkUser | string | `""` | Defaults to the 'default' user |
| haproxy.service.type | string | `"ClusterIP"` |  |
| haproxy.service.port | int | `6379` | Write port, follows the master |
| haproxy.service.annotations | object | `{}` |  |
| haproxy.config.maxconn | int | `4096` |  |
| haproxy.config.checkInterval | string | `"2s"` | How often HAProxy checks each node and Sentinel, the time it needs to notice a new master on top of Sentinel's own detection |
| haproxy.config.checkTimeout | string | `"5s"` |  |
| haproxy.config.healthPort | int | `8404` | Serves /healthz for the Kubernetes probes, not published |
| haproxy.config.timeout.connect | string | `"5s"` |  |
| haproxy.config.timeout.client | string | `"1m"` |  |
| haproxy.config.timeout.server | string | `"1m"` |  |
| haproxy.config.timeout.tunnel | string | `"24d"` | Keeps idle pub/sub connections open, 0 falls back to the client timeout |
| haproxy.tls.verify | string | `"required"` | Certificate validation towards the nodes, including each pod name |
| haproxy.tls.clientCertFile | string | `""` | Combined cert+key, required with tls.requireClientCertificate |
| haproxy.podDisruptionBudget.enabled | bool | `false` | Keep HAProxy replicas available across node drains |
| haproxy.podDisruptionBudget.minAvailable | int | `null` | Takes precedence over maxUnavailable |
| haproxy.podDisruptionBudget.maxUnavailable | int | `1` |  |
| haproxy.podDisruptionBudget.unhealthyPodEvictionPolicy | string | `""` |  |
| haproxy.nodeSelector | object | `null` | null inherits nodeSelector; {} for none |
| haproxy.tolerations | list | `null` | null inherits tolerations; [] for none |
| haproxy.podLabels | object | `{}` | HAProxy pod labels; top level podLabels do not apply |
| haproxy.podAnnotations | object | `{}` | HAProxy pod annotations; top level podAnnotations do not apply |
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
| sentinel.enabled | bool | `false` | Run Valkey Sentinel for automatic failover |
| sentinel.replicas | int | `3` | Number of independently deployed Sentinel pods |
| sentinel.port | int | `26379` |  |
| sentinel.masterSet | string | `"mymaster"` |  |
| sentinel.initialTopologyWaitSeconds | int | `180` | How long a pod with no recorded topology waits to be told one before giving up |
| sentinel.masterRecordRefreshSeconds | int | `1` | How often the cold-start topology record is checked against the running config |
| sentinel.quorum | int | `2` | Sentinels that must agree before a failover starts |
| sentinel.downAfterMilliseconds | int | `5000` |  |
| sentinel.failoverTimeout | int | `60000` |  |
| sentinel.parallelSyncs | int | `1` |  |
| sentinel.monitorUser | string | `""` | Defaults to replica.replicationUser |
| sentinel.orphanCheckSeconds | int | `30` | How often each Sentinel looks for a node replicating from something it cannot see |
| sentinel.password | string | `""` | Dedicated Sentinel password; this or existingSecret is required |
| sentinel.existingSecret | string | `""` | Secret holding the Sentinel password, instead of sentinel.password |
| sentinel.passwordKey | string | `"sentinel"` | Key of the Sentinel password in sentinel.existingSecret |
| sentinel.preStopFailover | bool | `true` | Fail over before a master pod is terminated |
| sentinel.preStopFailoverTimeoutSeconds | int | `20` |  |
| sentinel.startupTimeoutSeconds | int | `60` |  |
| sentinel.extraConfig | string | `""` | Raw lines appended to sentinel.conf; supports templating |
| sentinel.resources | object | `{}` |  |
| sentinel.securityContext | object | `{}` | Defaults to securityContext |
| sentinel.service.enabled | bool | `true` |  |
| sentinel.service.type | string | `"ClusterIP"` |  |
| sentinel.service.port | int | `26379` |  |
| sentinel.service.annotations | object | `{}` |  |
| sentinel.persistence.enabled | bool | `false` |  |
| sentinel.persistence.size | string | `"100Mi"` |  |
| sentinel.persistence.storageClass | string | `""` |  |
| sentinel.persistentVolumeClaimRetentionPolicy | object | `{}` | PVC retention policy for the Sentinel StatefulSet |
| sentinel.podLabels | object | `{}` | Sentinel pod labels; top level podLabels do not apply |
| sentinel.podAnnotations | object | `{}` | Sentinel pod annotations; top level podAnnotations do not apply |
| sentinel.nodeSelector | object | `null` | null inherits nodeSelector; {} for none |
| sentinel.tolerations | list | `null` | null inherits tolerations; [] for none |
| sentinel.affinity | object | `{}` | Top level affinity does not apply |
| sentinel.topologySpreadConstraints | list | `[]` | Top level topologySpreadConstraints do not apply |
| sentinel.podDisruptionBudget.enabled | bool | `false` | Keep a Sentinel quorum available across node drains |
| sentinel.podDisruptionBudget.minAvailable | int | `null` | Takes precedence over maxUnavailable |
| sentinel.podDisruptionBudget.maxUnavailable | int | `1` | Must keep max(quorum, majority) Sentinels running |
| sentinel.podDisruptionBudget.unhealthyPodEvictionPolicy | string | `""` |  |
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
| terminationGracePeriodSeconds | int | `30` | Valkey pods, standalone and replication; must exceed sentinel.preStopFailoverTimeoutSeconds |
| tls.caPublicKey | string | `"ca.crt"` |  |
| tls.dhParamKey | string | `""` |  |
| tls.enabled | bool | `false` |  |
| tls.existingSecret | string | `""` |  |
| tls.requireClientCertificate | bool | `false` |  |
| tls.serverKey | string | `"server.key"` |  |
| tls.serverPublicKey | string | `"server.crt"` |  |
| tolerations | list | `[]` |  |
| topologySpreadConstraints | list | `[]` | Valkey pods only, see sentinel.topologySpreadConstraints |
| valkeyLogLevel | string | `"notice"` |  |
| workloadAnnotations | object | `{}` |  |
