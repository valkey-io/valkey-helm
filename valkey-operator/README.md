# valkey-operator

![Version: 0.2.2](https://img.shields.io/badge/Version-0.2.2-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: v0.2.0](https://img.shields.io/badge/AppVersion-v0.2.0-informational?style=flat-square)

A Helm chart for deploying the [Valkey Operator](https://github.com/valkey-io/valkey-operator) on Kubernetes.

> **Note:** This chart is under active development. Some features are not yet available and are marked as TODOs in `values.yaml`.

> **Note:** This chart deploys the Valkey Operator, which manages ValkeyCluster resources. It is separate from the [valkey](../valkey/) chart, which deploys Valkey instances directly. You can use them independently

## Prerequisites

- Kubernetes 1.20+
- Helm 3.5+

## Upgrading

Helm does not upgrade CRDs automatically during `helm upgrade`. When upgrading between chart versions that include CRD changes, apply the CRDs manually first. See [UPGRADE.md](UPGRADE.md) for version-specific instructions.

## Installation

```bash
helm install valkey-operator valkey/valkey-operator \
  -n valkey-operator-system --create-namespace
```

This will deploy the operator into the `valkey-operator-system` namespace. By default the operator watches for `ValkeyCluster` resources across all namespaces. Set `manager.watchNamespaces` to restrict it to specific namespaces.

## Creating a ValkeyCluster

Once the operator is running, create a ValkeyCluster:

```yaml
apiVersion: valkey.io/v1alpha1
kind: ValkeyCluster
metadata:
  name: my-cluster
spec:
  shards: 3
  replicas: 1
```

## Configuration

See [values.yaml](values.yaml) for the full list of configurable parameters.

### Key parameters

| Parameter | Description | Default |
|---|---|---|
| `image.repository` | Operator image repository | `valkey-io/valkey-operator` |
| `image.tag` | Operator image tag | `""` (uses `.Chart.AppVersion`) |
| `replicaCount` | Number of operator replicas | `1` |
| `serviceAccount.create` | Create a ServiceAccount | `true` |
| `rbac.create` | Create ClusterRole and ClusterRoleBinding | `true` |
| `manager.leaderElection.enabled` | Enable leader election | `true` |
| `manager.watchNamespaces` | Restrict cache to these namespaces (cluster-wide if empty) | `[]` |
| `podDisruptionBudget.enabled` | Enable PodDisruptionBudget | `false` |
| `podDisruptionBudget.minAvailable` | Minimum pods available during disruptions | `null` |
| `podDisruptionBudget.maxUnavailable` | Maximum pods unavailable during disruptions | `1` |
| `podDisruptionBudget.unhealthyPodEvictionPolicy` | Policy for evicting unhealthy pods | `""` |
| `metrics.enabled` | Enable the metrics endpoint | `true` |
| `metrics.port` | Metrics endpoint port | `8443` |
| `metrics.secure` | Serve metrics over HTTPS with authn/authz | `false` |
| `metrics.reader.binding.create` | Bind a scraper SA to the metrics-reader role | `false` |
| `metrics.reader.binding.serviceAccountName` | Scraper SA to authorize (supports templating) | `""` |
| `metrics.reader.binding.namespace` | Scraper SA namespace (defaults to release namespace) | `""` |
| `resources.limits.cpu` | CPU limit | `500m` |
| `resources.limits.memory` | Memory limit | `128Mi` |
| `resources.requests.cpu` | CPU request | `10m` |
| `resources.requests.memory` | Memory request | `64Mi` |

## Metrics and RBAC

The operator exposes controller-runtime metrics on `metrics.port` (default `8443`).

When `rbac.create` is `true`, the chart ships two RBAC objects following the
kubebuilder convention:

- **metrics-auth** (`ClusterRole` + `ClusterRoleBinding` to the operator
  ServiceAccount): grants `create` on `tokenreviews.authentication.k8s.io` and
  `subjectaccessreviews.authorization.k8s.io`, so the operator can authenticate
  and authorize incoming scrape requests.
- **metrics-reader** (`ClusterRole`): grants `get` on the `/metrics`
  non-resource URL, so a scraper can be authorized to read metrics.

### Securing the metrics endpoint

By default the endpoint is served over plain HTTP (`metrics.secure: false`),
preserving the existing behavior. Set `metrics.secure: true` to serve metrics
over HTTPS and protect them with authn/authz (`--metrics-secure=true`):

```yaml
metrics:
  secure: true
```

When secured, scrapers must present a bearer token whose ServiceAccount is bound
to the `metrics-reader` ClusterRole. By default the chart leaves that binding to
the cluster admin. For example, to authorize a Prometheus ServiceAccount:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: valkey-operator-metrics-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: valkey-operator-metrics-reader
subjects:
- kind: ServiceAccount
  name: prometheus
  namespace: monitoring
```

Alternatively, let the chart create that binding by setting
`metrics.reader.binding`. The name and namespace support templating:

```yaml
metrics:
  reader:
    binding:
      create: true
      serviceAccountName: prometheus
      namespace: monitoring
```

## Source Code

* <https://github.com/valkey-io/valkey-operator>
