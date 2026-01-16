# valkey

![Version: 0.9.0](https://img.shields.io/badge/Version-0.9.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 9.0.1](https://img.shields.io/badge/AppVersion-9.0.1-informational?style=flat-square)

A Helm chart for Kubernetes

**Homepage:** <https://valkey.io/valkey-helm/>

## Maintainers

| Name | Url |
| ---- | --- |
| raven | [https://github.com/mk-raven] |
| sgissi | [https://github.com/sgissi] |

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

Persistent storage is **mandatory** in replication mode. Without it, the primary might comes up with an empty dataset after a restart, all replicas will synchronize with the empty primary and lose their data. See [Valkey Replication Safety](https://valkey.io/topics/replication/#safety-of-replication-when-primary-has-persistence-turned-off) for details.

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
| podSecurityContext.fsGroup | int | `1000` |  |
| podSecurityContext.runAsGroup | int | `1000` |  |
| podSecurityContext.runAsUser | int | `1000` |  |
| priorityClassName | string | `""` |  |
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
