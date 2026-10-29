# Valkey chart internals

How the chart works and why it is built this way.
This is background for maintainers and for operators debugging a deployment; the [README](../README.md) covers installing and configuring the chart.

## Valkey version

The chart replaces a Sentinel master through a coordinated failover (`SENTINEL FAILOVER <master> COORDINATED`), which Valkey added in 9.0.
That is why the chart requires Valkey 9.0 or later.

## Storage

The volume and claim names do not depend on the `persistence` values: the standalone PVC is named `<fullname>`, and the replication PVCs `valkey-data-<statefulset>-<index>`.

The standalone Deployment uses the `Recreate` strategy (`deploymentStrategy`): on an upgrade the old pod stops before the new one starts, so the data volume is never attached to two pods, at the cost of a short downtime.

In replication mode each pod gets its own PVC from the StatefulSet's `volumeClaimTemplates`.
Kubernetes does not allow changing `volumeClaimTemplates`, so `persistence.labels` and `persistence.annotations` only apply to new installs, and changing `accessModes` or `storageClass` later requires recreating the StatefulSet.

Persistence is mandatory with replication: without it, the primary might come up with an empty dataset after a restart, and all replicas synchronize with the empty primary and lose their data.
See [Valkey Replication Safety](https://valkey.io/topics/replication/#safety-of-replication-when-primary-has-persistence-turned-off).
Persistence narrows this but does not close it: a primary that crashes comes back with its last save, and the replicas drop every write made since then when they resynchronize from it.
Without Sentinel, enable AOF in `extraConfig` (`appendonly yes`) to keep that window to about a second; with Sentinel, the chart prevents it, see [Failover](#failover).

## Authentication

The chart regenerates the ACL file from the values whenever a pod starts, so users added at runtime with `ACL SETUSER` last only until the next restart.
A user allowed to run `ACL SAVE` or `CONFIG REWRITE` can still rewrite the generated files while the pod runs (`+@all` includes both), which is why application users should get narrower permissions such as `+@all -@admin`.

## Sentinel

### Scheduling and labels

The top level `affinity`, `topologySpreadConstraints`, `podLabels` and `podAnnotations` apply to the Valkey pods only, because rules written for the Valkey pods select the Valkey pods' labels.
The Sentinel and HAProxy pods take their own values under `sentinel.*` and `haproxy.*`.
`nodeSelector` and `tolerations` fall back to the top level values when the Sentinel or HAProxy ones are unset (`null`, the default); set them to `{}` / `[]` to schedule those pods without any.

The Valkey PodDisruptionBudget (`podDisruptionBudget`) does not cover the Sentinel pods; `sentinel.podDisruptionBudget` creates a separate one for them.

Sentinel can be enabled on an existing replication release without changing the Valkey StatefulSet's immutable fields.
Changing `sentinel.persistence.enabled` later changes the Sentinel StatefulSet's `volumeClaimTemplates` and therefore requires recreating that StatefulSet.

### Authentication

The Sentinel password is a credential used only for the Sentinel endpoint.
Clients, the Sentinels among themselves and the Valkey pods' scripts use it; the Valkey server never does.
Valkey user passwords are deliberately not accepted by Sentinel, so restrictions on application ACL users cannot be bypassed through Sentinel commands.

Sentinel reaches the Valkey nodes as `sentinel.monitorUser`, which defaults to `replica.replicationUser`.
That user must be allowed to promote a replica, otherwise every failover aborts with `-failover-abort-slave-timeout`.
A starting pod asks the other nodes which of them is the primary as the same user, rather than as `replica.replicationUser`, whose documented minimum cannot run `INFO`.
`+failover` and `+client` are what Sentinel needs for the coordinated failover, as listed in the [Sentinel documentation](https://valkey.io/topics/sentinel/).

### Credentials on disk

Valkey needs the replication password in plain text in its configuration, and `CONFIG REWRITE` writes it back on every failover even if the chart does not.
The configuration therefore lives on a memory backed `emptyDir` rather than on the data volume, so no credential is written to persistent storage.
The ACL file sits next to it on the same volume: it holds password hashes for `auth.aclUsers`, but `auth.aclConfig` is copied in as written, plain text passwords included.
The Sentinel state is memory backed for the same reason, since Sentinel rewrites `auth-pass` and `sentinel-pass` into `sentinel.conf`.
Only the RDB or AOF, the init log and, with Sentinel, the record of the last master (a host and port, no credential) stay on the data volume.

Enabling `sentinel.persistence` opts out of this and puts `sentinel.conf`, credentials included, on a PersistentVolume.
It is off by default and not needed, because each Sentinel rediscovers the current master on startup.

### Failover

A master that stops responding for `sentinel.downAfterMilliseconds` is replaced within a few seconds.
When a master pod is terminated, by a rolling update or a node drain, its `preStop` hook asks Sentinel for a coordinated failover (`SENTINEL FAILOVER <master> COORDINATED`) before the pod goes away.
Sentinel then has the master pause writes, wait until the chosen replica has all of them, and step down before that replica is promoted, so no acknowledged write is lost; clients writing during the handover wait briefly and then get an error or `-READONLY` and retry.
If the replica cannot catch up, the handover is rolled back instead.

`sentinel.minReadySeconds` keeps a rolling update from moving on until a restarted pod has been ready for that long.
Sentinel still marks a restarted pod as down for several seconds after it is ready, and does not repoint a pod it considers down when it fails over, so without the delay a pod can be left following a master that is about to go away.

A failover that is not planned, a crashed pod or a lost node, is not coordinated: Valkey replicates asynchronously, so the writes the master acknowledged last before it went away can be lost.
The Sentinel documentation covers this under [consistency under partitions](https://valkey.io/topics/sentinel/).

A master pod that crashes or is deleted forcibly is usually back before `sentinel.downAfterMilliseconds`, so Sentinel never fails over.
It would come back with its last save only, and its replicas would resynchronize from it and drop every write since.
So a pod that starts with no `replicaof` in its configuration, while Sentinel still names it the master and holds healthy replicas, waits instead of starting: Sentinel then sees the master down, promotes a replica, and the pod starts as a replica of it.
Writes are unavailable until the promotion, a few seconds after `sentinel.downAfterMilliseconds`, and reads keep working on the replicas.
If no replica is promoted within `sentinel.restartFailoverWaitSeconds`, e.g. without a Sentinel quorum, the pod starts as the master with the dataset on disk; keep the value well above `sentinel.downAfterMilliseconds`.
The wait carries over when the startup probe restarts the container, so that fallback comes on time.
A master container that comes back after Sentinel already promoted another node starts as that node's replica, and when no Sentinel answers at all, as on a cold start, the pod starts as configured.

### Cold start and the master record

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

### Orphaned replicas

Sentinel cannot repair that on its own, because it only learns which nodes are replicas by asking the primary, and a node replicating from a replica is not in that answer.
Each Sentinel therefore checks every `sentinel.orphanCheckSeconds` for a node that is replicating from something other than the current primary and that Sentinel does not list, and points it back at the primary.
It only touches nodes Sentinel cannot see, which are exactly the ones Sentinel is not reconfiguring itself, and it stands down entirely while the primary is not plainly up.
A node that answers as a primary is left alone and logged rather than demoted.

## HAProxy

### Routing

HAProxy health checks every Valkey node with `INFO replication` and asks every Sentinel which node is the master.
It forwards the write port only to the node that answers `role:master` and that a majority of the Sentinels name as the master.
The health checks are the failover mechanism, so no sidecar, no runtime package installation and no admin socket are involved.

HAProxy follows the Sentinels rather than `role:master` alone because an old master keeps answering `role:master` for several seconds after Sentinel has promoted a replica, and the writes it takes in that time are discarded when it resyncs.
The write port therefore also depends on the Sentinels: while a majority of them is unreachable, HAProxy closes new connections even if the master itself is healthy.

A failover has two steps, and HAProxy only covers the second one.
Sentinel first has to notice the failure (`sentinel.downAfterMilliseconds`) and promote a replica; HAProxy then needs up to `haproxy.config.checkInterval` to see the change in its health checks.
End to end that is the sum of both, not `checkInterval` alone.

When the old master goes away on its own `preStop` hook, it steps down before the new master is promoted, so connections that are already open get `-READONLY` and are closed by HAProxy at the next health check instead of writing to a stale master.
After an unplanned failover, they stay on the old master until Sentinel demotes it if it comes back.

There is no separate HAProxy read endpoint because `valkey-read` already load balances across every pod.
It only drops a pod based on the pod's own probes, and the readiness probe is off by default, so a pod that stops answering keeps receiving reads until the liveness probe restarts it (`livenessProbe.periodSeconds` times `livenessProbe.failureThreshold`, 30 seconds by default).
The readiness probe passes only on `PONG`, so with it enabled a replica that is still loading its dataset stays out of `valkey-read` until it can answer.

### Labels

The HAProxy pods are labelled `app.kubernetes.io/name: valkey-haproxy`, not `valkey`.
The Valkey PodDisruptionBudget and the headless and Sentinel services select on the name and instance without a component, so sharing the Valkey name would put the proxy pods behind all of them: the budget would count six pods instead of three, and the headless service would resolve to proxy addresses.

### Authentication

Both HAProxy passwords, the health check user's and the Sentinel one, are passed to HAProxy as environment variables read from their secrets, so they never land in a ConfigMap.

### TLS

With `tls.enabled`, HAProxy forwards the encrypted stream untouched and the client completes the TLS handshake with the Valkey node itself, so the connection stays encrypted end to end.

HAProxy never terminates a client's TLS connection.
Doing so would put one proxy certificate in front of every client, and on a node that maps a certificate to a user, every client would inherit that user's rights.
It follows that clients which cannot speak TLS cannot use this proxy against a TLS enabled cluster, because the nodes themselves listen on the TLS port only.

Of `tls.existingSecret` HAProxy only mounts what its health checks read, `tls.caPublicKey` and, when set, `haproxy.tls.clientCertFile`, so the Valkey server's private key never reaches the HAProxy pods.

With `haproxy.tls.verify: required`, HAProxy checks each pod separately, so a certificate issued for the service name alone fails, and every backend goes down with `Server presented an SSL certificate different from the configured one`.

HAProxy reads a client certificate and its private key from a single file, so the separate `tls.serverPublicKey` and `tls.serverKey` entries cannot serve as one.
Naming the key after the certificate, as `client.pem.key`, does not work either: that fallback is for `bind` lines, not for the backend `crt` the chart uses.
Leaving `haproxy.tls.clientCertFile` empty while `tls.requireClientCertificate` is set fails the install rather than starting a proxy whose health checks are refused by every node.

## TLS volumes

A volume given in `tls.volume` is mounted at `/tls` in every pod that reads TLS files: the Valkey pods, the Sentinel pods, the HAProxy pods and the test pods.

* Every file in it, private keys included, is readable in the Valkey, Sentinel and test pods.
* HAProxy mounts only the files it reads, the CA and its own client certificate, with `subPath`; the rest of the volume is still attached to its pods, but not visible in the container.
  Files mounted with `subPath` are not updated when they change, so HAProxy has to be restarted after rotating them; it only reads them on startup anyway.

TLS files cannot be added through `extraVolumeMounts`: mounts on `/tls`, or on any other path the chart uses, are refused.
