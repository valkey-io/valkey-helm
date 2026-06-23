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
| `metrics.enabled` | Enable the metrics endpoint | `true` |
| `metrics.port` | Metrics endpoint port | `8443` |
| `networkPolicy` | NetworkPolicy for the operator pod | `{}` |
| `resources.limits.cpu` | CPU limit | `500m` |
| `resources.limits.memory` | Memory limit | `128Mi` |
| `resources.requests.cpu` | CPU request | `10m` |
| `resources.requests.memory` | Memory request | `64Mi` |

### Network policy

In clusters that default-deny traffic, you can attach a NetworkPolicy to the operator pod via the `networkPolicy` value. Nothing is rendered unless `networkPolicy` is set, so the default behavior is unchanged.

Once you opt in, the chart automatically adds the egress the operator needs to function — DNS, the Kubernetes API server, and the managed Valkey pods on the Valkey port (`6379`) — so locking down egress doesn't break reconciliation. The Valkey egress rule targets the namespaces in `manager.watchNamespaces`; when that list is empty (watch all namespaces) it allows the Valkey port to every namespace. The `policyTypes` field is derived automatically from the rules in effect, and optional `labels` and `annotations` are added to the resource.

You can tune or disable this behavior:

| Field | Default | Description |
| --- | --- | --- |
| `networkPolicy.defaultEgressRules` | `true` | Inject the operator's required egress. Set `false` to manage all egress yourself. |
| `networkPolicy.valkeyPort` | `6379` | Port the operator uses to reach Valkey pods. |
| `networkPolicy.apiServerPort` | `6443` | Kubernetes API server port. |
| `networkPolicy.dnsNamespace` | `kube-system` | Namespace running kube-dns / CoreDNS. |

The operator pod exposes the metrics port (`8443` when `metrics.enabled`) and a health probe port (`8081`). The example below allows Prometheus to scrape metrics from a `monitoring` namespace; the operator egress rules are added for you:

```yaml
networkPolicy:
  labels: {}
  annotations: {}
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 8443
  # Any extra egress here is merged with the default operator egress rules.
  egress: []
```


## Source Code

* <https://github.com/valkey-io/valkey-operator>
