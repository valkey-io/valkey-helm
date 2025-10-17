# valkey

![Version: 0.7.5](https://img.shields.io/badge/Version-0.7.5-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 8.1.4](https://img.shields.io/badge/AppVersion-8.1.4-informational?style=flat-square)

A Helm chart for Kubernetes

**Homepage:** <https://valkey.io/valkey-helm/>

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` |  |
| auth.aclConfig | string | `"# Users and permissions can be defined here\n# Example:\n# user default off\n# user default on >defaultpassword ~*  &* +@all \n"` |  |
| auth.enabled | bool | `false` |  |
| commonLabels | object | `{}` |  |
| containerPorts.bus | int | `16379` |  |
| containerPorts.valkey | int | `6379` |  |
| dataStorage.accessModes[0] | string | `"ReadWriteOnce"` |  |
| dataStorage.annotations | object | `{}` |  |
| dataStorage.className | string | `nil` |  |
| dataStorage.enabled | bool | `false` |  |
| dataStorage.labels | object | `{}` |  |
| dataStorage.persistentVolumeClaimName | string | `nil` |  |
| dataStorage.requestedSize | string | `nil` |  |
| dataStorage.volumeName | string | `"valkey-data"` |  |
| env | object | `{}` |  |
| existingSecret | string | `""` |  |
| existingSecretPasswordKey | string | `""` |  |
| extraSecretValkeyConfigs | bool | `false` |  |
| extraStorage | list | `[]` |  |
| extraValkeyConfigs | list | `[]` |  |
| extraValkeySecrets | list | `[]` |  |
| fullnameOverride | string | `""` |  |
| global.imageRegistry | string | `""` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.registry | string | `"docker.io"` |  |
| image.repository | string | `"docker.io/valkey/valkey"` |  |
| image.tag | string | `""` |  |
| imagePullSecrets | list | `[]` |  |
| initResources | object | `{}` |  |
| lifecycleHooks | object | `{}` |  |
| metrics.containerPorts.http | int | `9121` |  |
| metrics.enabled | bool | `false` |  |
| metrics.exporter.extraExporterSecrets | list | `[]` |  |
| metrics.extraArgs | object | `{"is-cluster":"true","redis.addr":"redis://127.0.0.1:6379"}` |  |
| metrics.image.registry | string | `"docker.io"` |  |
| metrics.image.repository | string | `"oliver006/redis_exporter"` |  |
| metrics.image.tag | string | `"v1.78.0-alpine"` |  |
| metrics.resources | object | `{}` |  |
| metrics.service.clusterIP | string | `""` |  |
| metrics.service.type | string | `"ClusterIP"` |  |
| nameOverride | string | `""` |  |
| networkPolicy | object | `{}` |  |
| nodeSelector | object | `{}` |  |
| pdb.create | bool | `true` |  |
| pdb.maxUnavailable | string | `""` |  |
| pdb.minAvailable | string | `""` |  |
| podAnnotations | object | `{}` |  |
| podDisruptionBudget | object | `{}` |  |
| podLabels | object | `{}` |  |
| podSecurityContext.fsGroup | int | `1000` |  |
| podSecurityContext.runAsGroup | int | `1000` |  |
| podSecurityContext.runAsUser | int | `1000` |  |
| replicaCount | int | `1` |  |
| resources | object | `{}` |  |
| securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| securityContext.readOnlyRootFilesystem | bool | `true` |  |
| securityContext.runAsNonRoot | bool | `true` |  |
| securityContext.runAsUser | int | `1000` |  |
| service.type | string | `"ClusterIP"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.automount | bool | `false` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| tls.enabled | bool | `false` |  |
| tolerations | list | `[]` |  |
| topologySpreadConstraints | object | `{}` |  |
| valkeyConfig | string | `""` |  |
| valkeyLogLevel | string | `"notice"` |  |


## Source Code

* <https://github.com/valkey-io/valkey-helm.git>
* <https://valkey.io>

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| raven |  | <https://github.com/mk-raven> |
