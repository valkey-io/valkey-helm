# valkey

![Version: 0.5.1](https://img.shields.io/badge/Version-0.5.1-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 8.1.0](https://img.shields.io/badge/AppVersion-8.1.0-informational?style=flat-square)

A Helm chart for Kubernetes

**Homepage:** <https://github.com/mk-raven>
## Installation

1. Add valkey chart repository.
```
helm repo add valkey https://mk-raven.github.io/valkey-helm

```

2. Update local valkey chart information from chart repository.
```
helm repo update
```

3. Use the following commands to create the `valkey` namespace first, then install the valkey chart.

```
kubectl create namespace valkey
helm install valkey valkey/valkey --namespace valkey
```

## Uninstallation

```
helm uninstall valkey -n valkey
kubectl delete namespace valkey
```


## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` |  |
| auth.aclConfig | string | `"# Users and permissions can be defined here\n# Example:\n# user default off\n# user default on >defaultpassword ~* +@all \n"` |  |
| auth.enabled | bool | `false` |  |
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
| ingress.annotations | object | `{}` |  |
| ingress.className | string | `""` |  |
| ingress.enabled | bool | `false` |  |
| ingress.hosts[0].host | string | `"chart-example.local"` |  |
| ingress.hosts[0].paths[0].path | string | `"/"` |  |
| ingress.hosts[0].paths[0].pathType | string | `"ImplementationSpecific"` |  |
| ingress.tls | list | `[]` |  |
| initResources | object | `{}` |  |
| metrics.enabled | bool | `false` |  |
| metrics.exporter.extraExporterSecrets | list | `[]` |  |
| nameOverride | string | `""` |  |
| networkPolicy | object | `{}` |  |
| nodeSelector | object | `{}` |  |
| podAnnotations | object | `{}` |  |
| podLabels | object | `{}` |  |
| podSecurityContext | object | `{}` |  |
| replicaCount | int | `1` |  |
| resources | object | `{}` |  |
| securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| securityContext.readOnlyRootFilesystem | bool | `true` |  |
| securityContext.runAsNonRoot | bool | `true` |  |
| securityContext.runAsUser | int | `1000` |  |
| service.port | int | `6379` |  |
| service.type | string | `"ClusterIP"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.automount | bool | `true` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| storage.accessModes[0] | string | `"ReadWriteOnce"` |  |
| storage.annotations | object | `{}` |  |
| storage.className | string | `nil` |  |
| storage.keepPvc | bool | `false` |  |
| storage.labels | object | `{}` |  |
| storage.volumeName | string | `"valkey-data"` |  |
| tolerations | list | `[]` |  |
| valkeyConfig | string | `""` |  |
| valkeyLogLevel | string | `"notice"` |  |


## Source Code

* <https://github.com/mk-raven/valkey-helm.git>
* <https://valkey.io>

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| raven |  | <https://github.com/mk-raven> |