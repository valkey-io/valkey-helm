# valkey-operator

![Version: 0.3.0](https://img.shields.io/badge/Version-0.3.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: v0.3.0](https://img.shields.io/badge/AppVersion-v0.3.0-informational?style=flat-square)

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
| `rbac.create` | Create the operator ClusterRole/ClusterRoleBinding and the aggregated admin/editor/viewer ClusterRoles | `true` |
| `manager.leaderElection.enabled` | Enable leader election | `true` |
| `manager.watchNamespaces` | Restrict cache to these namespaces (cluster-wide if empty) | `[]` |
| `podDisruptionBudget.enabled` | Enable PodDisruptionBudget | `false` |
| `podDisruptionBudget.minAvailable` | Minimum pods available during disruptions | `null` |
| `podDisruptionBudget.maxUnavailable` | Maximum pods unavailable during disruptions | `1` |
| `podDisruptionBudget.unhealthyPodEvictionPolicy` | Policy for evicting unhealthy pods | `""` |
| `topologySpreadConstraints` | Topology spread constraints for the operator pods | `[]` |
| `metrics.enabled` | Enable the metrics endpoint | `true` |
| `metrics.port` | Metrics endpoint port | `8443` |
| `metrics.secure` | Serve metrics over HTTPS with authn/authz (passes `--metrics-secure=true`); renders the metrics RBAC. Requires `rbac.create` and `metrics.enabled` | `false` |
| `metrics.reader.binding.create` | Bind a scraper ServiceAccount to the `metrics-reader` ClusterRole. Requires `rbac.create`, `metrics.enabled`, and `metrics.secure` | `false` |
| `metrics.reader.binding.serviceAccountName` | Name of the scraper ServiceAccount to authorize. Supports templating; required when `binding.create` is `true` | `""` |
| `metrics.reader.binding.namespace` | Namespace of the scraper ServiceAccount. Supports templating; defaults to the release namespace when empty | `""` |
| `networkPolicy.enabled` | Enable creation of a NetworkPolicy for the operator pod | `false` |
| `resources.limits.cpu` | CPU limit | `500m` |
| `resources.limits.memory` | Memory limit | `128Mi` |
| `resources.requests.cpu` | CPU request | `10m` |
| `resources.requests.memory` | Memory request | `64Mi` |

### Network policy

In clusters that default-deny traffic, you can attach a NetworkPolicy to the operator pod by setting `networkPolicy.enabled: true`. It is disabled by default, so the default behavior is unchanged. This naming mirrors the [valkey chart](../valkey) (`enabled`, `extraIngress`, `extraEgress`) for a consistent experience across both charts.

Once enabled, the chart automatically adds the egress the operator needs to function — DNS, the Kubernetes API server, and the managed Valkey pods on the Valkey port (`6379`) — so locking down egress doesn't break reconciliation. The Valkey egress rule targets the namespaces in `manager.watchNamespaces`; when that list is empty (watch all namespaces) it allows the Valkey port to every namespace. The `policyTypes` field is derived automatically from the rules in effect, and optional `labels` and `annotations` are added to the resource.

You can tune or disable this behavior:

| Field | Default | Description |
| --- | --- | --- |
| `networkPolicy.enabled` | `false` | Enable creation of a NetworkPolicy for the operator pod. |
| `networkPolicy.defaultEgressRules` | `true` | Inject the operator's required egress. Set `false` to manage all egress yourself. |
| `networkPolicy.valkeyPort` | `6379` | Port the operator uses to reach Valkey pods. |
| `networkPolicy.apiServerPort` | `6443` | Kubernetes API server port. |
| `networkPolicy.dnsNamespace` | `kube-system` | Namespace running kube-dns / CoreDNS. |
| `networkPolicy.extraIngress` | `[]` | Additional ingress rules appended verbatim to the policy (templated with `tpl`). |
| `networkPolicy.extraEgress` | `[]` | Additional egress rules merged with the default operator egress (templated with `tpl`). |
| `networkPolicy.labels` | `{}` | Extra labels to add to the NetworkPolicy. |
| `networkPolicy.annotations` | `{}` | Extra annotations to add to the NetworkPolicy. |

The operator pod exposes the metrics port (`8443` when `metrics.enabled`) and a health probe port (`8081`). The example below allows Prometheus to scrape metrics from a `monitoring` namespace; the operator egress rules are added for you:

```yaml
networkPolicy:
  enabled: true
  labels: {}
  annotations: {}
  extraIngress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 8443
  # Any extra egress here is merged with the default operator egress rules.
  extraEgress: []
```

### Aggregated ClusterRoles

When `rbac.create` is enabled (the default), the chart also ships three aggregated
ClusterRoles for the `valkeyclusters` and `valkeynodes` custom resources, following the
[kubebuilder convention](https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles):

| Role | Aggregation label | Access |
|---|---|---|
| `*-valkey-admin` | `rbac.authorization.k8s.io/aggregate-to-admin` | Full management of the CRs (read-only on status) |
| `*-valkey-editor` | `rbac.authorization.k8s.io/aggregate-to-edit` | Create/update/delete the CRs (read-only on status) |
| `*-valkey-viewer` | `rbac.authorization.k8s.io/aggregate-to-view` | Read-only access to the CRs and status |

These roll up into the built-in `admin`, `edit`, and `view` ClusterRoles, so cluster
admins can grant tenants access to the Valkey CRDs without handing out the operator's own
controller permissions.

## Metrics and RBAC

By default the operator serves its controller-runtime metrics over plain HTTP. Set
`metrics.secure: true` to serve them over HTTPS with authentication and authorization,
following the [kubebuilder secure-metrics convention](https://book.kubebuilder.io/reference/metrics.html).
When secure serving is enabled (and `rbac.create` is `true`), the chart renders:

- a `*-metrics-auth` ClusterRole + ClusterRoleBinding granting the operator ServiceAccount
  `create` on `tokenreviews.authentication.k8s.io` and `subjectaccessreviews.authorization.k8s.io`,
  so it can authenticate and authorize incoming scrape requests; and
- a `*-metrics-reader` ClusterRole granting `get` on the `/metrics` non-resource URL.

A scraper must present a token whose ServiceAccount is bound to `metrics-reader`. You can
bind it yourself, or let the chart do it by opting in:

```yaml
metrics:
  secure: true
  reader:
    binding:
      create: true
      # Supports templating, e.g. "{{ .Release.Name }}-prometheus"
      serviceAccountName: prometheus
      # Defaults to the release namespace when empty
      namespace: monitoring
```

`serviceAccountName` is required when `binding.create` is `true`; rendering fails otherwise.
Both `metrics.secure` and `metrics.reader.binding.create` default to `false`, so existing
installs keep serving metrics over insecure HTTP unless you opt in.

## Source Code

* <https://github.com/valkey-io/valkey-operator>
