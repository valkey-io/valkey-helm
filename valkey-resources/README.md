# valkey-resources

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: v0.3.0](https://img.shields.io/badge/AppVersion-v0.3.0-informational?style=flat-square)

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

`cluster.spec` is a drop-in for `ValkeyCluster.spec` (passed through as-is). Nested under `cluster` so future CR kinds can sit beside it without a generic top-level `spec`. Helm owns metadata (`fullname`, `cluster.labels`, `cluster.annotations`).

More granular values and defaults will be added iteratively. See [values.yaml](values.yaml) and the [ValkeyCluster API](https://github.com/valkey-io/valkey-operator/blob/main/docs/valkeycluster.md).

| Parameter | Description | Default |
|---|---|---|
| `cluster.spec.shards` | Shard groups | `3` |
| `cluster.spec.replicas` | Replicas per shard | `1` |
| `fullnameOverride` | ValkeyCluster name | chart fullname |

One cluster per release. For more clusters, install more releases.

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
