# Changelog

## 0.1.2

### Changed

- `appVersion` defaults to operator **v0.4.0**. Workloads created from this chart must target a cluster whose ValkeyCluster CRD matches v0.4.0 (install or upgrade the `valkey-operator` chart / CRDs first). See the [v0.4.0 release notes](https://github.com/valkey-io/valkey-operator/releases/tag/v0.4.0).

Breaking ValkeyCluster API changes in operator v0.4.0 that matter for `cluster.spec` drop-in values:

- Placement fields live under `cluster.spec.scheduling` (`affinity`, `nodeSelector`, `tolerations`, `topologySpreadConstraints`, `priorityClassName`). Top-level copies of those fields are gone.
- Node host spread: `cluster.spec.scheduling.node.spread.{shard,primaries,pods}.mode` (`Disabled` | `Preferred` | `Required`). Defaults are opt-in (`Disabled`). Prefer this over a bare hostname topology spread for shard anti-colocation.
- `cluster.spec.podDisruptionBudget` is an object, e.g. `{ mode: Cluster }` or `{ mode: Disabled }` (no longer a bare string `Managed` / `Disabled`).

## 0.1.1

### Added

- Optional Prometheus Operator PodMonitor for ValkeyNode `metrics-exporter` sidecars (`metrics.podMonitor`). Selector uses `valkey.io/cluster` matching the ValkeyCluster name.

## 0.1.0

### Added

- Initial `valkey-resources` chart: one `ValkeyCluster` per release via `cluster.spec` drop-in.
- Helm `tpl` on `cluster.spec`, labels, and annotations; top-level `extraValues` for template helpers.
- Unit tests, values schema, release and unittest CI wiring.
