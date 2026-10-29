# valkey

![Version: 1.0.0-rc.1](https://img.shields.io/badge/Version-1.0.0--rc.1-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 9.1.3](https://img.shields.io/badge/AppVersion-9.1.3-informational?style=flat-square)

Valkey, an open source, high-performance in-memory datastore

> **1.0.0-rc.1 is a release candidate.** The current stable release is **0.12.1**, which a plain `helm install` still installs. This README describes 1.0.0-rc.1, whose values differ from 0.12.1, so the examples need `--version 1.0.0-rc.1`. To move an existing release from 0.12.1, see [UPGRADE.md](UPGRADE.md).

**Homepage:** <https://valkey.io/valkey-helm/>

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| raven |  | <https://github.com/mk-raven> |
| sgissi |  | <https://github.com/sgissi> |
| Bloodraven21 |  | <https://github.com/Bloodraven21> |

## Source Code

* <https://github.com/valkey-io/valkey-helm.git>
* <https://valkey.io>

## Requirements

* Valkey 9.0 or later. The default image is a 9.x release; if you pin `image.tag`, pin a 9.x version.

## Quick Start

The chart is published both as a Helm repository and as an OCI artifact.

**Helm repository:**

```bash
helm repo add valkey https://valkey.io/valkey-helm/
helm repo update
# Stable release, 0.12.1
helm install valkey valkey/valkey
# Release candidate
helm install valkey valkey/valkey --version 1.0.0-rc.1
```

**OCI registry:**

```bash
# Stable release
helm install valkey oci://ghcr.io/valkey-io/valkey-helm/valkey --version 0.12.1
# Release candidate
helm install valkey oci://ghcr.io/valkey-io/valkey-helm/valkey --version 1.0.0-rc.1
```

The examples below are for the release candidate and use `valkey/valkey`; add `--version 1.0.0-rc.1` to each, or replace `valkey/valkey` with `oci://ghcr.io/valkey-io/valkey-helm/valkey --version 1.0.0-rc.1` to install from the OCI registry.
Service names assume a release named `valkey`.

These commands are the shortest way to try each mode and run without authentication.
See [Before Going to Production](#before-going-to-production) for a real deployment.

### Standalone

A single Valkey pod. This is the default.

```bash
helm install valkey valkey/valkey
```

| Service  | Use         |
|----------|-------------|
| `valkey` | Read/write  |

### Replicated

One primary and two replicas. Replication requires persistent storage.

```bash
helm install valkey valkey/valkey \
  --set replica.enabled=true \
  --set persistence.enabled=true \
  --set persistence.size=5Gi
```

| Service           | Use                                     |
|-------------------|-----------------------------------------|
| `valkey`          | Read/write, always the primary (pod-0)  |
| `valkey-read`     | Read-only, load balanced over all pods  |
| `valkey-headless` | Pod discovery                           |

The primary is fixed to pod-0: if it fails, writes stop until it comes back.
Use Sentinel for automatic failover.

### Sentinel (High Availability)

Replicated mode plus three Sentinel pods that promote a replica when the primary fails.
Sentinel always requires its own password.

```bash
helm install valkey valkey/valkey \
  --set replica.enabled=true \
  --set persistence.enabled=true \
  --set persistence.size=5Gi \
  --set sentinel.enabled=true \
  --set sentinel.password=change-me
```

| Service              | Use                                                  |
|----------------------|------------------------------------------------------|
| `valkey-sentinel`    | Sentinel, port 26379: ask it for the current primary |
| `valkey-read`        | Read-only, load balanced over all pods               |
| `valkey`             | Any pod, not a write endpoint                        |
| `valkey-headless`    | Pod discovery                                        |
| `valkey-sentinel-hl` | Sentinel pod discovery                               |

The primary can be any pod, so clients must use a Sentinel-aware library, or the [HAProxy front-end](#haproxy-front-end).

### Connecting

**Standalone and replicated:**

```bash
kubectl port-forward svc/valkey 6379:6379
valkey-cli -h 127.0.0.1 ping
```

From inside the cluster, connect to `valkey.<namespace>.svc.cluster.local:6379`.

**Sentinel:**

```bash
kubectl exec valkey-sentinel-0 -- valkey-cli -p 26379 --user sentinel -a change-me \
  SENTINEL get-master-addr-by-name mymaster
```

Applications resolve the primary through Sentinel, for example in Python:

```python
from valkey.sentinel import Sentinel

sentinel = Sentinel(
    [("valkey-sentinel", 26379)],
    sentinel_kwargs={"username": "sentinel", "password": "change-me"},
)
primary = sentinel.master_for("mymaster")
primary.set("key", "value")
```

When `auth.enabled` is set, also pass the Valkey `username` and `password` to `master_for`.
The notes printed by `helm install` show the commands for your release.

### Uninstalling

```bash
helm uninstall valkey
```

In replicated and Sentinel mode the PersistentVolumeClaims are kept; delete them with `kubectl delete pvc -l app.kubernetes.io/instance=valkey` to remove the data.
In standalone mode the PersistentVolumeClaim is deleted unless `persistence.keepOnUninstall` is set.

## Before Going to Production

* Enable [authentication](#authentication) and keep passwords in a Secret.
* Size `persistence` for your dataset and pick a `persistence.storageClass`.
* Enable [TLS](#tls) if traffic leaves a trusted network.
* Enable a [PodDisruptionBudget](#poddisruptionbudget) and spread pods across nodes or zones with `affinity` or `topologySpreadConstraints`.
* For Sentinel, keep passwords in Secrets with `auth.usersExistingSecret` and `sentinel.existingSecret`, and spread the Sentinel pods too (see [Sentinel](#sentinel)).

A complete Sentinel values file with authentication is in [examples/ha-sentinel.yaml](examples/ha-sentinel.yaml).

## Upgrading

Breaking changes and migration steps are listed in [UPGRADE.md](UPGRADE.md).

## Configuration

### Persistence

The `persistence` block configures the Valkey data directory (`/data`).

```yaml
persistence:
  enabled: true
  size: 10Gi
  storageClass: "fast-ssd"  # Optional
```

In standalone mode persistence is optional; without it data lives in an `emptyDir` and is lost whenever the pod is replaced, e.g. on an upgrade or eviction.
Standalone can also use an existing claim (`persistence.existingClaim`) or a `persistence.hostPath`, and `persistence.keepOnUninstall: true` keeps the PVC on `helm uninstall`.

In replicated and Sentinel mode persistence is required and each pod gets its own PVC, named `valkey-data-<statefulset>-<index>`.
To reuse existing volumes, create claims with those names before installing.
`existingClaim`, `hostPath` and `keepOnUninstall` do not apply; Helm never deletes these PVCs unless `replica.persistentVolumeClaimRetentionPolicy` says so.
`accessModes`, `storageClass`, `persistence.labels` and `persistence.annotations` cannot be changed after install.

### Authentication

When `auth.enabled` is set, the `default` user must be defined in `auth.aclUsers` or `auth.aclConfig`.

**Passwords from an existing Secret (recommended):**

```yaml
auth:
  enabled: true
  usersExistingSecret: "my-valkey-users"
  aclUsers:
    default:
      permissions: "~* &* +@all"
      # Password read from the Secret key "default" (the username)
    readonly:
      permissions: "~* -@all +@read +ping +info"
      passwordKey: "readonly-pwd"  # Custom Secret key
```

**Inline passwords:**

```yaml
auth:
  enabled: true
  aclUsers:
    default:
      permissions: "~* &* +@all"
      password: "default-password"
```

When `usersExistingSecret` is set, passwords from the Secret take precedence over inline ones.

**Raw ACL rules**, appended after the generated users:

```yaml
auth:
  enabled: true
  aclConfig: |
    user default on >defaultpassword ~* &* +@all
    user guest on nopass ~public:* +@read
```

The ACL file is regenerated from these values on every pod start: users added with `ACL SETUSER` are lost on restart.
A user allowed to run `ACL SAVE` or `CONFIG REWRITE`, which `+@all` includes, can overwrite the generated files while the pod runs: give application users narrower permissions, e.g. `+@all -@admin`.

**With replication**, replicas authenticate to the primary as `replica.replicationUser`, which must be defined in `auth.aclUsers` with at least `+psync +replconf +ping`:

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
  replicationUser: "replication-user"
```

### Replication

`replica.replicas` counts the Valkey pods, the primary included (default 3).

To reject writes unless enough replicas are in sync:

```yaml
replica:
  minReplicasToWrite: 1  # At least 1 replica connected
  minReplicasMaxLag: 10  # With at most 10 seconds of lag
```

`valkey-read` drops a pod only when its probes fail.
Enable `readinessProbe` to take an unresponsive or still-loading replica out of `valkey-read` faster.

### Sentinel

Sentinel requires `replica.enabled`, at least 2 Valkey pods and at least 3 Sentinels (`sentinel.replicas`).

**Authentication:** Sentinel uses two separate credentials, one in each direction.

| Connection         | User                                              | Password                                         |
|--------------------|---------------------------------------------------|--------------------------------------------------|
| Clients → Sentinel | `sentinel`                                        | `sentinel.password` or `sentinel.existingSecret` |
| Sentinel → Valkey  | `sentinel.monitorUser` (only with `auth.enabled`) | That user's password from `auth.aclUsers`        |

Every Sentinel has a single ACL user, `sentinel`, which clients, HAProxy and the Sentinels themselves log in as.
Its password is required even when `auth.enabled` is off: set `sentinel.password`, or point `sentinel.existingSecret` at a Secret holding it under `sentinel.passwordKey` (default `sentinel`).
The `default` user is disabled on Sentinel, and the users in `auth.aclUsers` do not exist there.
A client therefore needs both credentials: `sentinel` to look up the primary, then its own Valkey user to connect to it.

With `auth.enabled`, Sentinel logs in to the Valkey nodes as `sentinel.monitorUser`, which defaults to `replica.replicationUser` and must be defined in `auth.aclUsers`.
That user needs these permissions, otherwise failovers abort:

```text
~* &* +multi +exec +ping +info +role +subscribe +publish +slaveof +replicaof
+config|rewrite +client +failover +script|kill +psync +replconf
```

**Scheduling:** Sentinel pods take their own `sentinel.affinity`, `sentinel.topologySpreadConstraints`, `sentinel.podLabels` and `sentinel.podAnnotations`; the top level ones apply to Valkey pods only.
`sentinel.nodeSelector` and `sentinel.tolerations` fall back to the top level values when unset.
Spread the Sentinels so a single node or zone cannot take down the quorum, and protect them with their own PodDisruptionBudget:

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
  podDisruptionBudget:
    enabled: true
    maxUnavailable: 1
```

**Failover:** a primary that stops responding for `sentinel.downAfterMilliseconds` (5 seconds by default) is replaced within a few seconds.
Planned restarts (upgrades, node drains) hand over to a replica first without losing acknowledged writes (`sentinel.preStopFailover`, on by default); clients see a brief `-READONLY` or connection error and should retry.
An unplanned failure can lose the last writes acknowledged by the old primary.

Sentinel can be enabled on an existing replicated release with `helm upgrade`.

#### HAProxy Front-End

For clients that do not support Sentinel, HAProxy provides a fixed endpoint that always points at the current primary:

```bash
helm install valkey valkey/valkey \
  --set replica.enabled=true \
  --set persistence.enabled=true \
  --set persistence.size=5Gi \
  --set sentinel.enabled=true \
  --set sentinel.password=change-me \
  --set haproxy.enabled=true
```

| Service          | Use                                    |
|------------------|----------------------------------------|
| `valkey-haproxy` | Read/write, always the current primary |

Use `valkey-read` for reads.
After a failover clients get connection errors until HAProxy sees the new primary, up to `sentinel.downAfterMilliseconds` plus `haproxy.config.checkInterval`, and must reconnect.

HAProxy runs 3 pods by default (`haproxy.replicas`), labelled `app.kubernetes.io/name: valkey-haproxy` and `app.kubernetes.io/component: haproxy`.
Like the Sentinels, they take their own `haproxy.affinity`, `haproxy.topologySpreadConstraints`, `haproxy.podLabels`, `haproxy.podAnnotations`, `haproxy.nodeSelector` and `haproxy.tolerations`, and their own `haproxy.podDisruptionBudget`.

With authentication, HAProxy health checks Valkey as `haproxy.checkUser` (default `default`), which needs `+info` and `+ping`.

**With TLS**, the client's TLS session goes through HAProxy to the Valkey node, so clients connect with TLS as they would to Valkey directly. HAProxy cannot serve non-TLS clients in front of a TLS cluster.

* Add the HAProxy service name, e.g. `valkey-haproxy.<namespace>.svc.cluster.local`, to the server certificate's SANs.
* With the default `haproxy.tls.verify: required`, the certificate must also cover each pod's DNS name: `valkey-<index>.valkey-headless.<namespace>.svc.cluster.local` and `valkey-sentinel-<index>.valkey-sentinel-hl.<namespace>.svc.cluster.local`.
  Replace `cluster.local` if you set `clusterDomain`.
  Alternatively set `haproxy.tls.verify: none` to keep the health checks encrypted without validating the certificate.

With `tls.requireClientCertificate`, HAProxy needs a client certificate signed by `tls.caPublicKey`, with the certificate and key concatenated in one file of `tls.existingSecret`:

```bash
cat client.crt client.key > client.pem
kubectl create secret generic valkey-tls \
  --from-file=ca.crt --from-file=server.crt --from-file=server.key --from-file=client.pem
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

### TLS

Create a Secret with the server certificate, its key and the CA certificate:

```bash
kubectl create secret generic valkey-tls-secret \
  --from-file=server.crt --from-file=server.key --from-file=ca.crt
```

```yaml
tls:
  enabled: true
  existingSecret: "valkey-tls-secret"
```

`tls.serverPublicKey`, `tls.serverKey` and `tls.caPublicKey` set the key names in the Secret.
For a cert-manager Secret, use `serverPublicKey: tls.crt` and `serverKey: tls.key`.

**Files from another volume:** when the files do not come from a single Secret, set `tls.volume` to any volume source instead.
For example, to combine a cert-manager certificate without `ca.crt` with a trust-manager CA bundle:

```yaml
tls:
  enabled: true
  volume:
    projected:
      sources:
        - secret:
            name: valkey-cert
            items:
              - {key: tls.crt, path: server.crt}
              - {key: tls.key, path: server.key}
        - configMap:
            name: valkey-ca-bundle
            items:
              - {key: trust-bundle.pem, path: ca.crt}
```

The volume is mounted at `/tls` by the Valkey, Sentinel, HAProxy and test pods:

* It must support being mounted by several pods at once; a ReadWriteOnce PersistentVolumeClaim does not.
* Every file in it, private keys included, is readable in the Valkey, Sentinel and test pods. HAProxy sees only the CA and its client certificate.
* The files must be readable by the users those pods run as.
* Restart HAProxy after rotating the files.

TLS files cannot be mounted through `extraVolumeMounts`; mounts on `/tls` or any other path the chart uses are refused.

### Metrics

Prometheus metrics are exposed by a [Redis exporter](https://github.com/oliver006/redis_exporter) sidecar:

```yaml
metrics:
  enabled: true
  serviceMonitor:
    enabled: true  # Requires the Prometheus Operator
```

`metrics.podMonitor` and `metrics.prometheusRule` create a PodMonitor and a PrometheusRule instead of, or next to, the ServiceMonitor.

### PodDisruptionBudget

Available in replicated and Sentinel mode; it covers the Valkey pods only (see [Sentinel](#sentinel) for the Sentinel pods).

```yaml
podDisruptionBudget:
  enabled: true
  maxUnavailable: 1  # Or minAvailable: 2
```

### NetworkPolicy

`networkPolicy.enabled` creates a NetworkPolicy for the Valkey pods.
It does not cover the Sentinel or HAProxy pods, which stay reachable from anywhere.
By default it admits clients from anywhere on the Valkey port, opens the metrics port when `metrics.enabled` is set, and allows all egress.

To admit only known clients, set `networkPolicy.allowExternal: false`.
The Valkey port then accepts only:

* pods labelled `valkey-client: "true"` (`<fullname>-client`),
* the other Valkey pods, and this release's Sentinel and HAProxy pods,
* pods in namespaces matching `networkPolicy.ingressNSMatchLabels`, narrowed by `networkPolicy.ingressNSPodMatchLabels`.

```yaml
networkPolicy:
  enabled: true
  allowExternal: false
  ingressNSMatchLabels:
    kubernetes.io/metadata.name: my-app
```

`networkPolicy.allowExternalEgress: false` limits egress to DNS, the other Valkey pods and this release's Sentinel pods.
`networkPolicy.extraIngress` and `networkPolicy.extraEgress` add further rules; they can only widen what the policy allows.

### Custom Configuration

* `extraConfig`: lines appended to `valkey.conf` (templated). `sentinel.extraConfig` does the same for `sentinel.conf`.
* `extraEnv`: environment variables for the Valkey container (`metrics.exporter.extraEnv` for the exporter).
* `extraVolumes` / `extraVolumeMounts`: additional volumes for the Valkey container (`metrics.exporter.extraVolumeMounts` for the exporter).

For example, to include configuration from a Secret:

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
```

## Cluster Mode

This chart does not support Valkey cluster mode.
Use the `valkey-operator` and `valkey-resources` charts in this repository instead.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` |  |
| auth.aclConfig | string | `""` |  |
| auth.aclUsers | object | `{}` |  |
| auth.enabled | bool | `false` |  |
| auth.usersExistingSecret | string | `""` |  |
| clusterDomain | string | `"cluster.local"` |  |
| commonLabels | object | `{}` |  |
| deploymentStrategy | string | `"Recreate"` |  |
| extraConfig | string | `""` |  |
| extraContainers | list | `[]` |  |
| extraEnv | list | `[]` |  |
| extraInitContainers | list | `[]` |  |
| extraVolumeMounts | list | `[]` |  |
| extraVolumes | list | `[]` |  |
| fullnameOverride | string | `""` |  |
| global.imagePullSecrets | list | `[]` |  |
| global.imageRegistry | string | `""` |  |
| haproxy.affinity | object | `{}` |  |
| haproxy.checkUser | string | `""` |  |
| haproxy.config.checkInterval | string | `"2s"` |  |
| haproxy.config.checkTimeout | string | `"5s"` |  |
| haproxy.config.healthPort | int | `8404` |  |
| haproxy.config.maxconn | int | `4096` |  |
| haproxy.config.timeout.client | string | `"1m"` |  |
| haproxy.config.timeout.connect | string | `"5s"` |  |
| haproxy.config.timeout.server | string | `"1m"` |  |
| haproxy.config.timeout.tunnel | string | `"24d"` |  |
| haproxy.enabled | bool | `false` |  |
| haproxy.extraInitContainers | list | `[]` |  |
| haproxy.extraVolumeMounts | list | `[]` |  |
| haproxy.extraVolumes | list | `[]` |  |
| haproxy.image.pullPolicy | string | `"IfNotPresent"` |  |
| haproxy.image.registry | string | `"docker.io"` |  |
| haproxy.image.repository | string | `"haproxy"` |  |
| haproxy.image.tag | string | `"3.2-alpine"` |  |
| haproxy.nodeSelector | string | `nil` |  |
| haproxy.podAnnotations | object | `{}` |  |
| haproxy.podDisruptionBudget.enabled | bool | `false` |  |
| haproxy.podDisruptionBudget.maxUnavailable | int | `1` |  |
| haproxy.podDisruptionBudget.minAvailable | string | `nil` |  |
| haproxy.podDisruptionBudget.unhealthyPodEvictionPolicy | string | `""` |  |
| haproxy.podLabels | object | `{}` |  |
| haproxy.podSecurityContext.fsGroup | int | `99` |  |
| haproxy.podSecurityContext.runAsGroup | int | `99` |  |
| haproxy.podSecurityContext.runAsUser | int | `99` |  |
| haproxy.podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| haproxy.replicas | int | `3` |  |
| haproxy.resources | object | `{}` |  |
| haproxy.securityContext.allowPrivilegeEscalation | bool | `false` |  |
| haproxy.securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| haproxy.securityContext.readOnlyRootFilesystem | bool | `true` |  |
| haproxy.securityContext.runAsNonRoot | bool | `true` |  |
| haproxy.service.annotations | object | `{}` |  |
| haproxy.service.clusterIP | string | `""` |  |
| haproxy.service.loadBalancerClass | string | `""` |  |
| haproxy.service.loadBalancerSourceRanges | list | `[]` |  |
| haproxy.service.nodePort | int | `0` |  |
| haproxy.service.port | int | `6379` |  |
| haproxy.service.type | string | `"ClusterIP"` |  |
| haproxy.tls.clientCertFile | string | `""` |  |
| haproxy.tls.verify | string | `"required"` |  |
| haproxy.tolerations | string | `nil` |  |
| haproxy.topologySpreadConstraints | list | `[]` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.registry | string | `"docker.io"` |  |
| image.repository | string | `"valkey/valkey"` |  |
| image.tag | string | `""` |  |
| imagePullSecrets | list | `[]` |  |
| initResources | object | `{}` |  |
| livenessProbe.customProbe | object | `{}` |  |
| livenessProbe.enabled | bool | `true` |  |
| livenessProbe.failureThreshold | int | `3` |  |
| livenessProbe.initialDelaySeconds | int | `0` |  |
| livenessProbe.periodSeconds | int | `10` |  |
| livenessProbe.timeoutSeconds | int | `1` |  |
| metrics.enabled | bool | `false` |  |
| metrics.exporter.args | list | `[]` |  |
| metrics.exporter.command | list | `[]` |  |
| metrics.exporter.extraEnv | list | `[]` |  |
| metrics.exporter.extraVolumeMounts | list | `[]` |  |
| metrics.exporter.image.pullPolicy | string | `"IfNotPresent"` |  |
| metrics.exporter.image.registry | string | `"ghcr.io"` |  |
| metrics.exporter.image.repository | string | `"oliver006/redis_exporter"` |  |
| metrics.exporter.image.tag | string | `"v1.88.0"` |  |
| metrics.exporter.port | int | `9121` |  |
| metrics.exporter.resources | object | `{}` |  |
| metrics.exporter.securityContext.allowPrivilegeEscalation | bool | `false` |  |
| metrics.exporter.securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| metrics.exporter.securityContext.readOnlyRootFilesystem | bool | `true` |  |
| metrics.exporter.securityContext.runAsNonRoot | bool | `true` |  |
| metrics.exporter.tlsServerName | string | `""` |  |
| metrics.podMonitor.annotations | object | `{}` |  |
| metrics.podMonitor.enabled | bool | `false` |  |
| metrics.podMonitor.honorLabels | bool | `false` |  |
| metrics.podMonitor.interval | string | `"30s"` |  |
| metrics.podMonitor.labels | object | `{}` |  |
| metrics.podMonitor.metricRelabelings | list | `[]` |  |
| metrics.podMonitor.podTargetLabels | list | `[]` |  |
| metrics.podMonitor.port | string | `"metrics"` |  |
| metrics.podMonitor.relabelings | list | `[]` |  |
| metrics.podMonitor.sampleLimit | bool | `false` |  |
| metrics.podMonitor.scrapeTimeout | string | `""` |  |
| metrics.podMonitor.targetLimit | bool | `false` |  |
| metrics.prometheusRule.annotations | object | `{}` |  |
| metrics.prometheusRule.enabled | bool | `false` |  |
| metrics.prometheusRule.labels | object | `{}` |  |
| metrics.prometheusRule.rules | list | `[]` |  |
| metrics.service.annotations | object | `{}` |  |
| metrics.service.appProtocol | string | `""` |  |
| metrics.service.clusterIP | string | `""` |  |
| metrics.service.enabled | bool | `true` |  |
| metrics.service.labels | object | `{}` |  |
| metrics.service.loadBalancerClass | string | `""` |  |
| metrics.service.loadBalancerSourceRanges | list | `[]` |  |
| metrics.service.nodePort | int | `0` |  |
| metrics.service.port | int | `9121` |  |
| metrics.service.type | string | `"ClusterIP"` |  |
| metrics.serviceMonitor.annotations | object | `{}` |  |
| metrics.serviceMonitor.enabled | bool | `false` |  |
| metrics.serviceMonitor.honorLabels | bool | `false` |  |
| metrics.serviceMonitor.interval | string | `"30s"` |  |
| metrics.serviceMonitor.labels | object | `{}` |  |
| metrics.serviceMonitor.metricRelabelings | list | `[]` |  |
| metrics.serviceMonitor.podTargetLabels | list | `[]` |  |
| metrics.serviceMonitor.port | string | `"metrics"` |  |
| metrics.serviceMonitor.relabelings | list | `[]` |  |
| metrics.serviceMonitor.sampleLimit | bool | `false` |  |
| metrics.serviceMonitor.scrapeTimeout | string | `""` |  |
| metrics.serviceMonitor.targetLimit | bool | `false` |  |
| nameOverride | string | `""` |  |
| networkPolicy.allowExternal | bool | `true` |  |
| networkPolicy.allowExternalEgress | bool | `true` |  |
| networkPolicy.annotations | object | `{}` |  |
| networkPolicy.enabled | bool | `false` |  |
| networkPolicy.extraEgress | list | `[]` |  |
| networkPolicy.extraIngress | list | `[]` |  |
| networkPolicy.ingressNSMatchLabels | object | `{}` |  |
| networkPolicy.ingressNSPodMatchLabels | object | `{}` |  |
| networkPolicy.labels | object | `{}` |  |
| nodeSelector | object | `{}` |  |
| persistence.accessModes[0] | string | `"ReadWriteOnce"` |  |
| persistence.annotations | object | `{}` |  |
| persistence.enabled | bool | `false` |  |
| persistence.existingClaim | string | `""` |  |
| persistence.hostPath | string | `""` |  |
| persistence.keepOnUninstall | bool | `false` |  |
| persistence.labels | object | `{}` |  |
| persistence.size | string | `""` |  |
| persistence.storageClass | string | `""` |  |
| persistence.subPath | string | `""` |  |
| podAnnotations | object | `{}` |  |
| podDisruptionBudget.enabled | bool | `false` |  |
| podDisruptionBudget.maxUnavailable | int | `1` |  |
| podDisruptionBudget.minAvailable | string | `nil` |  |
| podDisruptionBudget.unhealthyPodEvictionPolicy | string | `""` |  |
| podLabels | object | `{}` |  |
| podSecurityContext.fsGroup | int | `1000` |  |
| podSecurityContext.runAsGroup | int | `1000` |  |
| podSecurityContext.runAsUser | int | `1000` |  |
| podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| priorityClassName | string | `""` |  |
| readinessProbe.customProbe | object | `{}` |  |
| readinessProbe.enabled | bool | `false` |  |
| readinessProbe.failureThreshold | int | `3` |  |
| readinessProbe.initialDelaySeconds | int | `0` |  |
| readinessProbe.periodSeconds | int | `10` |  |
| readinessProbe.successThreshold | int | `1` |  |
| readinessProbe.timeoutSeconds | int | `1` |  |
| replica.disklessSync | bool | `false` |  |
| replica.enabled | bool | `false` |  |
| replica.minReplicasMaxLag | int | `10` |  |
| replica.minReplicasToWrite | int | `0` |  |
| replica.persistentVolumeClaimRetentionPolicy | object | `{}` |  |
| replica.replicas | int | `3` |  |
| replica.replicationUser | string | `"default"` |  |
| replica.service.annotations | object | `{}` |  |
| replica.service.appProtocol | string | `""` |  |
| replica.service.clusterIP | string | `""` |  |
| replica.service.enabled | bool | `true` |  |
| replica.service.loadBalancerClass | string | `""` |  |
| replica.service.loadBalancerSourceRanges | list | `[]` |  |
| replica.service.nodePort | int | `0` |  |
| replica.service.port | int | `6379` |  |
| replica.service.type | string | `"ClusterIP"` |  |
| resources | object | `{}` |  |
| runtimeClassName | string | `""` |  |
| securityContext.allowPrivilegeEscalation | bool | `false` |  |
| securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| securityContext.readOnlyRootFilesystem | bool | `true` |  |
| securityContext.runAsNonRoot | bool | `true` |  |
| securityContext.runAsUser | int | `1000` |  |
| sentinel.affinity | object | `{}` |  |
| sentinel.downAfterMilliseconds | int | `5000` |  |
| sentinel.enabled | bool | `false` |  |
| sentinel.existingSecret | string | `""` |  |
| sentinel.extraConfig | string | `""` |  |
| sentinel.failoverTimeout | int | `60000` |  |
| sentinel.initialTopologyWaitSeconds | int | `180` |  |
| sentinel.masterRecordRefreshSeconds | int | `1` |  |
| sentinel.masterSet | string | `"mymaster"` |  |
| sentinel.minReadySeconds | int | `15` |  |
| sentinel.monitorUser | string | `""` |  |
| sentinel.nodeSelector | string | `nil` |  |
| sentinel.orphanCheckSeconds | int | `30` |  |
| sentinel.parallelSyncs | int | `1` |  |
| sentinel.password | string | `""` |  |
| sentinel.passwordKey | string | `"sentinel"` |  |
| sentinel.persistence.accessModes[0] | string | `"ReadWriteOnce"` |  |
| sentinel.persistence.enabled | bool | `false` |  |
| sentinel.persistence.size | string | `"100Mi"` |  |
| sentinel.persistence.storageClass | string | `""` |  |
| sentinel.persistentVolumeClaimRetentionPolicy | object | `{}` |  |
| sentinel.podAnnotations | object | `{}` |  |
| sentinel.podDisruptionBudget.enabled | bool | `false` |  |
| sentinel.podDisruptionBudget.maxUnavailable | int | `1` |  |
| sentinel.podDisruptionBudget.minAvailable | string | `nil` |  |
| sentinel.podDisruptionBudget.unhealthyPodEvictionPolicy | string | `""` |  |
| sentinel.podLabels | object | `{}` |  |
| sentinel.port | int | `26379` |  |
| sentinel.preStopFailover | bool | `true` |  |
| sentinel.preStopFailoverTimeoutSeconds | int | `20` |  |
| sentinel.quorum | int | `2` |  |
| sentinel.replicas | int | `3` |  |
| sentinel.resources | object | `{}` |  |
| sentinel.restartFailoverWaitSeconds | int | `120` |  |
| sentinel.securityContext | object | `{}` |  |
| sentinel.service.annotations | object | `{}` |  |
| sentinel.service.appProtocol | string | `""` |  |
| sentinel.service.clusterIP | string | `""` |  |
| sentinel.service.enabled | bool | `true` |  |
| sentinel.service.loadBalancerClass | string | `""` |  |
| sentinel.service.loadBalancerSourceRanges | list | `[]` |  |
| sentinel.service.nodePort | int | `0` |  |
| sentinel.service.port | int | `26379` |  |
| sentinel.service.type | string | `"ClusterIP"` |  |
| sentinel.startupTimeoutSeconds | int | `60` |  |
| sentinel.tolerations | string | `nil` |  |
| sentinel.topologySpreadConstraints | list | `[]` |  |
| service.annotations | object | `{}` |  |
| service.appProtocol | string | `""` |  |
| service.clusterIP | string | `""` |  |
| service.loadBalancerClass | string | `""` |  |
| service.loadBalancerSourceRanges | list | `[]` |  |
| service.nodePort | int | `0` |  |
| service.port | int | `6379` |  |
| service.type | string | `"ClusterIP"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.automount | bool | `false` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| startupProbe.customProbe | object | `{}` |  |
| startupProbe.enabled | bool | `true` |  |
| startupProbe.failureThreshold | int | `3` |  |
| startupProbe.initialDelaySeconds | int | `0` |  |
| startupProbe.periodSeconds | int | `10` |  |
| startupProbe.timeoutSeconds | int | `1` |  |
| terminationGracePeriodSeconds | int | `30` |  |
| tls.caPublicKey | string | `"ca.crt"` |  |
| tls.dhParamKey | string | `""` |  |
| tls.enabled | bool | `false` |  |
| tls.existingSecret | string | `""` |  |
| tls.requireClientCertificate | bool | `false` |  |
| tls.serverKey | string | `"server.key"` |  |
| tls.serverPublicKey | string | `"server.crt"` |  |
| tls.volume | object | `{}` |  |
| tolerations | list | `[]` |  |
| topologySpreadConstraints | list | `[]` |  |
| valkeyLogLevel | string | `"notice"` |  |
| workloadAnnotations | object | `{}` |  |
