# Changelog

## 0.2.0

### Changed

- `appVersion` defaults to operator **v0.6.0** (up from v0.4.0). Workloads created from this chart must target a cluster whose ValkeyCluster CRD matches v0.6.0 (install or upgrade the `valkey-operator` chart / CRDs first). See the [v0.6.0 release notes](https://github.com/valkey-io/valkey-operator/releases/tag/v0.6.0).
- Reworked [`examples/scheduling-zone-spread.yaml`](examples/scheduling-zone-spread.yaml) to use the first-class `scheduling.zone.spread` API (added in operator v0.5.0) instead of hand-written `topologySpreadConstraints`. The operator now owns the emitted constraints, and the example uses `shard.mode: Preferred` for soft, zone-aware placement.

Breaking ValkeyCluster API change that matters for `cluster.spec` drop-in values:

- TLS certificate reference moved from `spec.networking.tls.certificate.secretName` to `spec.networking.tls.certificates.server.secretName`. Update TLS-enabled clusters accordingly.

### Notes

- This release skips operator v0.5.0. If upgrading from a chart release on appVersion v0.4.0, note that v0.5.0 first moved `spec.tls` to `spec.networking.tls`; v0.6.0 then moved `certificate` to `certificates.server`. Both changes are reflected in the current examples and values.
- Operator v0.5.0 also added the `scheduling.zone.spread` and `scheduling.zone.pinning` axes (zone-aware placement mirroring `scheduling.node.spread`). The `scheduling-zone-spread.yaml` example uses `zone.spread`; `zone.spread` and `zone.pinning` are mutually exclusive.

## 0.1.3

### Added

- Example values under [`examples/`](examples/): minimal topology, `scheduling.node.spread`, zone topology spread, TLS secret ref, persistence, PodMonitor, and ACL users.
- Index and usage notes in [`examples/README.md`](examples/README.md).

### Notes

- Helm unittest smoke renders for the examples directory are deferred to a follow-up.

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
