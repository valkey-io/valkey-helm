# valkey-resources

![Version: 0.4.0](https://img.shields.io/badge/Version-0.4.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: v0.8.0](https://img.shields.io/badge/AppVersion-v0.8.0-informational?style=flat-square)

Deploys a single operator managed `ValkeyCluster`. Does not install the operator.

## Prerequisites

* Kubernetes 1.31+
* Helm 3.5+
* [valkey-operator](../valkey-operator/) **v0.8.0+** installed (CRDs present)

Without matching CRDs the API server rejects `ValkeyCluster` on apply. Helm does not upgrade CRDs for you; apply the operator chart CRDs when moving to v0.8.0. See [CHANGELOG.md](CHANGELOG.md) and the operator [v0.8.0](https://github.com/valkey-io/valkey-operator/releases/tag/v0.8.0) notes.

## Install

```bash
helm install valkey-operator valkey/valkey-operator \
  -n valkey-operator-system --create-namespace

helm install my-cluster valkey/valkey-resources -n valkey
```

### Examples

Copy-paste values for common shapes live under [`examples/`](examples/) (operator v0.6.0+). Start with `minimal.yaml` and `scheduling-node-spread.yaml` for production node HA via `scheduling.node.spread`. See [`examples/README.md`](examples/README.md).

```bash
helm install my-cluster ./valkey-resources -n valkey \
  -f valkey-resources/examples/scheduling-node-spread.yaml
```

Further examples and helm unittest render smoke for that directory are planned as a follow-up.

## Configuration

`cluster.spec` is a drop-in for `ValkeyCluster.spec` (any CRD field). Nested under `cluster` so future CR kinds can sit beside it without a generic top-level `spec`.

String values in `cluster.spec`, `cluster.labels`, and `cluster.annotations` are run through Helm `tpl`, so you can reference release metadata or `extraValues`:

```yaml
extraValues:
  tlsSecret: my-shared-tls

cluster:
  spec:
    shards: 3
    replicas: 1
    networking:
      tls:
        certificates:
          server:
            secretName: "{{ .Values.extraValues.tlsSecret }}"
```

### `cluster.spec` scheduling and PDB shape (since operator v0.4.0)

Placement and PDB fields changed in the CRD. Use the nested forms in values:

```yaml
cluster:
  spec:
    shards: 3
    replicas: 1
    podDisruptionBudget:
      mode: Cluster   # or Disabled
    scheduling:
      priorityClassName: high-priority
      node:
        spread:
          shard:
            mode: Required    # same-shard pods not co-located (anti-affinity)
          primaries:
            mode: Preferred
          pods:
            mode: Disabled
```

See [values.yaml](values.yaml), [CHANGELOG.md](CHANGELOG.md), and the [ValkeyCluster API](https://github.com/valkey-io/valkey-operator/blob/main/docs/valkeycluster.md).

| Parameter | Description | Default |
|---|---|---|
| `cluster.spec.shards` | Shard groups | `3` |
| `cluster.spec.replicas` | Replicas per shard | `1` |
| `extraValues` | Free-form map for use inside `tpl` strings | `{}` |
| `metrics.podMonitor.enabled` | Create a PodMonitor for ValkeyNode exporter sidecars (Prometheus Operator CRDs) | `false` |
| `metrics.podMonitor.port` | Scrape port name on the exporter container | `metrics` |
| `fullnameOverride` | ValkeyCluster name | chart fullname |

### Metrics (PodMonitor)

Operator pods run a `metrics-exporter` sidecar (port name `metrics`, 9121) when `cluster.spec.exporter` is enabled (operator default). This chart can create a **PodMonitor** that selects pods with `valkey.io/cluster=<ValkeyCluster name>` in the release namespace:

```yaml
metrics:
  podMonitor:
    enabled: true
    labels:
      release: prometheus
```

Use PodMonitor (not ServiceMonitor): node metrics are on pods, not a dedicated Service. Operator controller metrics stay on the `valkey-operator` chart ServiceMonitor.

### NetworkPolicy

Set `networkPolicy.enabled: true` to render a NetworkPolicy named after the ValkeyCluster. It selects pods with `valkey.io/cluster=<ValkeyCluster name>` and admits only what the cluster needs to run:

- the cluster's own pods on the `client` (6379) and `cluster-bus` (16379) ports
- the operator on the `client` port, so it can reconcile (`networkPolicy.operator`, default: pods labelled `app.kubernetes.io/name: valkey-operator` in any namespace)

Egress is open by default (`networkPolicy.allowExternalEgress: true`, as in the valkey chart). With `allowExternalEgress: false` egress is limited to the cluster's own pods on `client` and `cluster-bus` and to UDP and TCP 53 in `networkPolicy.dnsNamespace` (default `kube-system`).

Everything else, including your clients and a Prometheus scraping the exporter (`metrics`, 9121), goes in `extraIngress` and `extraEgress`. Both are lists of NetworkPolicy rules appended as they are and templated with `tpl`:

```yaml
networkPolicy:
  enabled: true
  extraIngress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: "{{ .Release.Namespace }}"
      ports:
        - port: client
          protocol: TCP
  extraEgress: []
```

Rules use the operator's named container ports, `client`, `cluster-bus` and `metrics`, so they follow the pods if the port numbers change. The CNI must support named ports in NetworkPolicy (Calico and Cilium do).

The operator rule is dropped when `networkPolicy.operator` is null or empty. Helm merges overrides into the default peer, so to replace it set the default's `namespaceSelector` or `podSelector` key to null alongside your own.

`extraIngress` and `extraEgress` add rules on top; Kubernetes admits a connection if any rule matches, so they can only widen what the policy allows. They are lists, so a later values file replaces them whole. `networkPolicy.labels` and `networkPolicy.annotations` go on the policy object. The policy only has an effect when the CNI enforces NetworkPolicy. See [examples/network-policy.yaml](examples/network-policy.yaml).

**Release model:** one logical workload per Helm release. v0.1 only renders `ValkeyCluster`. When more kinds land, the chart will keep that model (enable the kinds you need for that one workload; multiple independent clusters remain multiple releases).

## Uninstall

```bash
helm uninstall my-cluster -n valkey
```

Deletes the ValkeyCluster. Child objects are garbage collected by the operator.
PVCs follow the cluster persistence reclaim policy.

## Related charts

| Chart | Role |
|---|---|
| [valkey](../valkey/) | Standalone/replication without operator |
| [valkey-operator](../valkey-operator/) | Installs the operator |
| **valkey-resources** | Operator managed CRs |
