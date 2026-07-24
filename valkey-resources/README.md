# valkey-resources

![Version: 0.1.1](https://img.shields.io/badge/Version-0.1.1-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: v0.3.0](https://img.shields.io/badge/AppVersion-v0.3.0-informational?style=flat-square)

Deploys a single operator managed `ValkeyCluster`. Does not install the operator.

## Prerequisites

* Kubernetes 1.20+
* Helm 3.5+
* [valkey-operator](../valkey-operator/) installed (CRDs present)

Without CRDs the API server rejects `ValkeyCluster` on apply.

## Install

```bash
helm install valkey-operator valkey/valkey-operator \
  -n valkey-operator-system --create-namespace

helm install my-cluster valkey/valkey-resources -n valkey
```

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
    tls:
      certificate:
        secretName: "{{ .Values.extraValues.tlsSecret }}"
```

See [values.yaml](values.yaml) and the [ValkeyCluster API](https://github.com/valkey-io/valkey-operator/blob/main/docs/valkeycluster.md).

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
