# valkey-operator

![Version: 0.2.0](https://img.shields.io/badge/Version-0.2.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: v0.2.0](https://img.shields.io/badge/AppVersion-v0.2.0-informational?style=flat-square)

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

This will deploy the operator into the `valkey-operator-system` namespace. The operator will watch for `ValkeyCluster` custom resources across all namespaces.

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
| `metrics.enabled` | Enable the metrics endpoint | `true` |
| `metrics.port` | Metrics endpoint port | `8443` |
| `resources.limits.cpu` | CPU limit | `500m` |
| `resources.limits.memory` | Memory limit | `128Mi` |
| `resources.requests.cpu` | CPU request | `10m` |
| `resources.requests.memory` | Memory request | `64Mi` |

## Source Code

* <https://github.com/valkey-io/valkey-operator>
