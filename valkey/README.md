# valkey

![Version: 0.7.7](https://img.shields.io/badge/Version-0.7.7-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 8.1.4](https://img.shields.io/badge/AppVersion-8.1.4-informational?style=flat-square)

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
| auth.aclConfig | string | `"# Users and permissions can be defined here\n# Example:\n# user default off\n# user default on >defaultpassword ~*  &* +@all \n"` |  |
| auth.enabled | bool | `false` |  |
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
| deploymentStrategy | string | `"RollingUpdate"` |  |
| env | object | `{}` |  |
| extraSecretValkeyConfigs | bool | `false` |  |
| extraStorage | list | `[]` |  |
| extraValkeyConfigs | list | `[]` |  |
| extraValkeySecrets | list | `[]` |  |
| fullnameOverride | string | `""` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
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
| replicaCount | int | `1` |  |
| resources | object | `{}` |  |
| securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| securityContext.readOnlyRootFilesystem | bool | `true` |  |
| securityContext.runAsNonRoot | bool | `true` |  |
| securityContext.runAsUser | int | `1000` |  |
| service.annotations | object | `{}` |  |
| service.nodePort | int | `0` |  |
| service.port | int | `6379` |  |
| service.type | string | `"ClusterIP"` |  |
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