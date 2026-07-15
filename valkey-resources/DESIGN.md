# valkey-resources design

## Summary

Third chart in `valkey-helm`. Deploys operator managed CRs (v0.1: one `ValkeyCluster` per release). Does not install the operator or CRDs. Naming from [discussion #212](https://github.com/valkey-io/valkey-helm/discussions/212).

## Motivation

Today you install the operator via helm, then hand apply `ValkeyCluster` YAML. A chart gives GitOps and `helm upgrade` a first class path for workload CRs, separate from the operator lifecycle (cluster scoped, slow changing) and from the non operator `valkey` chart (standalone/replication).

## Tradeoffs

### Spec drop-in vs granular Helm values

| | Spec drop-in (v0.1 chosen) | Granular Helm values |
|---|---|---|
| Maintenance | tracks operator 1:1 | dual schema |
| Drift | none | rises with every CRD change |
| UX | values look like the CR | enable gates, image compose, secret tpl |

**v0.1:** `values.spec` is dropped into `ValkeyCluster.spec` via `toYaml`. Helm owns metadata only.

**Later:** expand iteratively toward more granular values and defaults (same direction as the `valkey` chart: `persistence.enabled`, composed images, templated secret names, etc.) without a big bang rewrite.

### One cluster per release vs multi cluster list

| | One (chosen) | Multi |
|---|---|---|
| Upgrade/rollback | clean | partial updates awkward |
| GitOps | one release = one intent | list templating |

Multi cluster is a GitOps concern, not this chart.

### CRD ownership

CRDs live in `valkey-operator`. This chart never ships them.

### Secrets

Refs only (TLS secret name, ACL password secrets). No secret generation in v0.1.

### Umbrella vs separate charts

Separate. Operator and workload upgrade cadences differ.

### Validation

| Layer | Role |
|---|---|
| `values.schema.json` | types, required shards |
| helm unittest | render shape |
| operator CRD / CEL | real invariants |

### Relationship to `valkey`

Keep separate audiences. Do not run both for the same workload.

## Detailed design

### Layout

```
valkey-resources/
  Chart.yaml
  values.yaml
  values.schema.json
  templates/
    _helpers.tpl
    valkeycluster.yaml
    NOTES.txt
  tests/
  README.md
  DESIGN.md
```

### Values and templating

```yaml
nameOverride: ""
fullnameOverride: ""
commonLabels: {}
annotations: {}
labels: {}

# Dropped into ValkeyCluster.spec as-is
spec:
  shards: 3
  replicas: 1
```

Template: metadata from helpers, `spec: {{- toYaml .Values.spec | nindent 2 }}`. New CRD fields work without chart changes. Real validation stays on the CRD.

Resource name uses the same `fullname` helper as the other charts. Namespace is the release namespace.

### Install and uninstall

1. Install `valkey-operator` (once per cluster).
2. Install this chart per workload.

No chart side operator probe. Missing CRDs fail at apply time (API server: no matches for kind ValkeyCluster). Normal for CR workload charts.

Uninstall deletes the `ValkeyCluster`. Operator GCs children. PVCs follow persistence reclaim policy.

### Versioning and release cadence

* Chart version independent of operator.
* `appVersion`: operator tag tested against (signal, not a hard gate).
* Pre v1 values breaks are allowed; document them.

**Cadence (chosen):** start with **weekly releases** while PR volume is high. Avoids noisy index churn and lets a few merges land together with one version bump. Revisit later; may move to **per merged PR** releases once the chart stabilizes (optional, not committed).

### Compatibility

Needs operator with `ValkeyCluster` `valkey.io/v1alpha1` and `spec.scheduling` nesting (no legacy top level affinity fields).

## Scope

### v1
* `ValkeyCluster` only, one per release
* Podmonitor for Valkeynodes
* Spec drop-in values (`values.spec` → CR spec)
* Lint, unittest, README, NOTES
* CI unittest + release path
* Weekly chart releases initially
* Granular values (iterative later)

### v1+ scope
* Secret generation
* Standalone / Sentinel CRs
* Kind e2e (follow up)
* Support for `type: Deployment` (?)

### Out of scope
* Multiple clusters per helm release
* Additional kinds when those APIs exist (still one logical deployment per release)

## Open questions

1. Default object name: `<release_name>-<valkey>-<mode>` (e.g. `app-a-valkey-cluster` or `app-b-valkey-sentinel`). Users can always set `fullnameOverride`.
2. How strict should `values.schema.json` get beyond `shards` / `replicas`?
3. When (if ever) to switch from weekly to per PR releases?

## References

* [Name poll #212](https://github.com/valkey-io/valkey-helm/discussions/212)
* [ValkeyCluster docs](https://github.com/valkey-io/valkey-operator/blob/main/docs/valkeycluster.md)
* [Operator samples](https://github.com/valkey-io/valkey-operator/tree/main/config/samples)
* [SchedulingSpec proposal #284](https://github.com/valkey-io/valkey-operator/discussions/284)
* [Scheduling API epic #299](https://github.com/valkey-io/valkey-operator/issues/299)
* Tech calls 2026-07-03 / 2026-07-10 (one cluster per release, release cadence, design owners)

## Implementation
1. Scaffold chart + design (first PR # TODO)
2. Pod monitor
3. Example values (persistence, TLS ref, users, scheduling)
4. Optional kind e2e after operator install
5. Future CR kinds when operator APIs land
6. Shared helm auto docs (Sagar track)
