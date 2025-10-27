# valkey

![Version: 0.7.6](https://img.shields.io/badge/Version-0.7.6-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 8.1.4](https://img.shields.io/badge/AppVersion-8.1.4-informational?style=flat-square)

A Helm chart for Kubernetes

**Homepage:** <https://valkey.io/valkey-helm/>

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| raven |  | <https://github.com/mk-raven> |

## Source Code

* <https://github.com/valkey-io/valkey-helm.git>
* <https://valkey.io>

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` |  |
| auth.acl.config | string | `""` |  |
| auth.acl.enabled | bool | `false` |  |
| auth.acl.existingSecret | string | `""` |  |
| auth.acl.existingSecretKey | string | `"acl.conf"` |  |
| auth.aclConfig | string | `"# Users and permissions can be defined here\n# Example:\n# user default off\n# user default on >defaultpassword ~*  &* +@all\n"` |  |
| auth.enabled | bool | `false` |  |
| auth.existingSecret | string | `""` |  |
| auth.existingSecretPasswordKey | string | `"password"` |  |
| auth.password | string | `""` |  |
| backup.affinity | object | `{}` |  |
| backup.annotations | object | `{}` |  |
| backup.compression.enabled | bool | `true` |  |
| backup.compression.level | int | `6` |  |
| backup.enabled | bool | `false` |  |
| backup.encryption.enabled | bool | `false` |  |
| backup.encryption.gpgRecipient | string | `""` |  |
| backup.extraEnv | list | `[]` |  |
| backup.failedJobsHistoryLimit | int | `3` |  |
| backup.image.pullPolicy | string | `"IfNotPresent"` |  |
| backup.image.repository | string | `"amazon/aws-cli"` |  |
| backup.image.tag | string | `"latest"` |  |
| backup.labels | object | `{}` |  |
| backup.nodeSelector | object | `{}` |  |
| backup.resources.limits.cpu | string | `"500m"` |  |
| backup.resources.limits.memory | string | `"512Mi"` |  |
| backup.resources.requests.cpu | string | `"100m"` |  |
| backup.resources.requests.memory | string | `"128Mi"` |  |
| backup.retention.hourly | int | `240` |  |
| backup.schedule | string | `"0 * * * *"` |  |
| backup.storage.azure.container | string | `""` |  |
| backup.storage.azure.existingSecret | string | `""` |  |
| backup.storage.azure.prefix | string | `"backups/"` |  |
| backup.storage.azure.storageAccount | string | `""` |  |
| backup.storage.gcs.bucket | string | `""` |  |
| backup.storage.gcs.existingSecret | string | `""` |  |
| backup.storage.gcs.prefix | string | `"backups/"` |  |
| backup.storage.gcs.projectId | string | `""` |  |
| backup.storage.s3.accessKeyId | string | `""` |  |
| backup.storage.s3.bucket | string | `""` |  |
| backup.storage.s3.endpoint | string | `""` |  |
| backup.storage.s3.existingSecret | string | `""` |  |
| backup.storage.s3.pathStyle | bool | `false` |  |
| backup.storage.s3.prefix | string | `"backups/"` |  |
| backup.storage.s3.region | string | `"us-east-1"` |  |
| backup.storage.s3.secretAccessKey | string | `""` |  |
| backup.storage.type | string | `"s3"` |  |
| backup.successfulJobsHistoryLimit | int | `3` |  |
| backup.tolerations | list | `[]` |  |
| dataStorage.accessModes[0] | string | `"ReadWriteOnce"` |  |
| dataStorage.annotations | object | `{}` |  |
| dataStorage.className | string | `""` |  |
| dataStorage.enabled | bool | `false` |  |
| dataStorage.keepPvc | bool | `false` |  |
| dataStorage.labels | object | `{}` |  |
| dataStorage.persistentVolumeClaimName | string | `""` |  |
| dataStorage.requestedSize | string | `""` |  |
| dataStorage.sentinelSize | string | `"1Gi"` |  |
| dataStorage.volumeName | string | `"valkey-data"` |  |
| deploymentStrategy | string | `"RollingUpdate"` |  |
| env | object | `{}` |  |
| extraContainers | list | `[]` |  |
| extraInitContainers | list | `[]` |  |
| extraSecretValkeyConfigs | bool | `false` |  |
| extraStorage | list | `[]` |  |
| extraValkeyConfigs | list | `[]` |  |
| extraValkeySecrets | list | `[]` |  |
| extraVolumeMounts | list | `[]` |  |
| extraVolumes | list | `[]` |  |
| fullnameOverride | string | `""` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.repository | string | `"docker.io/valkey/valkey"` |  |
| image.tag | string | `""` |  |
| imagePullSecrets | list | `[]` |  |
| initResources | object | `{}` |  |
| logging.level | string | `"notice"` |  |
| logging.slowlogLogSlowerThan | int | `10000` |  |
| logging.slowlogMaxLen | int | `128` |  |
| metrics.enabled | bool | `false` |  |
| metrics.exporter.extraExporterSecrets | list | `[]` |  |
| metrics.exporter.image.pullPolicy | string | `"IfNotPresent"` |  |
| metrics.exporter.image.repository | string | `"oliver006/redis_exporter"` |  |
| metrics.exporter.image.tag | string | `"v1.55.0"` |  |
| metrics.exporter.resources | object | `{}` |  |
| metrics.serviceMonitor.annotations | object | `{}` |  |
| metrics.serviceMonitor.enabled | bool | `false` |  |
| metrics.serviceMonitor.interval | string | `"30s"` |  |
| metrics.serviceMonitor.labels | object | `{}` |  |
| metrics.serviceMonitor.namespace | string | `""` |  |
| nameOverride | string | `""` |  |
| networkPolicy.annotations | object | `{}` |  |
| networkPolicy.egress | list | `[]` |  |
| networkPolicy.enabled | bool | `false` |  |
| networkPolicy.ingress | list | `[]` |  |
| networkPolicy.labels | object | `{}` |  |
| networkPolicy.policyTypes | list | `[]` |  |
| nodeSelector | object | `{}` |  |
| podAnnotations | object | `{}` |  |
| podDisruptionBudget.enabled | bool | `false` |  |
| podLabels | object | `{}` |  |
| podSecurityContext.fsGroup | int | `1000` |  |
| podSecurityContext.runAsGroup | int | `1000` |  |
| podSecurityContext.runAsUser | int | `1000` |  |
| replicaCount | int | `1` |  |
| replication.antiAffinity.enabled | bool | `true` |  |
| replication.antiAffinity.topologyKey | string | `"kubernetes.io/hostname"` |  |
| replication.antiAffinity.type | string | `"hard"` |  |
| replication.disklessSync | bool | `true` |  |
| replication.disklessSyncDelay | int | `5` |  |
| replication.minReplicas.maxLag | int | `10` |  |
| replication.minReplicas.toWrite | int | `1` |  |
| replication.readOnly | bool | `true` |  |
| resources | object | `{}` |  |
| securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| securityContext.readOnlyRootFilesystem | bool | `true` |  |
| securityContext.runAsNonRoot | bool | `true` |  |
| securityContext.runAsUser | int | `1000` |  |
| sentinel | object | `{"affinity":{},"announce":{"enabled":true},"antiAffinity":{"enabled":true,"topologyKey":"kubernetes.io/hostname","type":"hard"},"auth":{"enabled":false,"existingSecret":"","existingSecretPasswordKey":"sentinel-password","password":""},"customConfig":"","downAfterMilliseconds":30000,"enabled":false,"failoverTimeout":180000,"image":{"pullPolicy":"","repository":"","tag":""},"nodeSelector":{},"parallelSyncs":1,"port":26379,"quorum":2,"replicas":3,"resources":{},"tolerations":[]}` | --------------------------------------------------------------------------- |
| service.annotations | object | `{}` |  |
| service.labels | object | `{}` |  |
| service.nodePort | int | `0` |  |
| service.port | int | `6379` |  |
| service.type | string | `"ClusterIP"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.automount | bool | `false` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| standalone | object | `{"enabled":true}` | --------------------------------------------------------------------------- |
| tls.certCAFilename | string | `"ca.crt"` |  |
| tls.certFilename | string | `"tls.crt"` |  |
| tls.certKeyFilename | string | `"tls.key"` |  |
| tls.certificatesSecret | string | `""` |  |
| tls.enabled | bool | `false` |  |
| tolerations | list | `[]` |  |
| topologySpreadConstraints | list | `[]` |  |
| updateStrategy.rollingUpdate.maxUnavailable | int | `1` |  |
| updateStrategy.type | string | `"RollingUpdate"` |  |
| valkeyConfig | string | `""` |  |
| valkeyLogLevel | string | `"notice"` |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
