# Upgrading the valkey-resources chart

## From 0.6.x

### Validated `cluster.spec`

**What changed:** `cluster.spec` was a pass-through to `ValkeyCluster.spec`. It is now validated by `values.schema.json`, which is generated from the ValkeyCluster CRD at the chart's `appVersion` (v0.9.0). The schema rejects keys the CRD does not have, so `helm install`, `helm upgrade`, `helm lint` and `helm template` fail on them. Kubernetes types embedded in the spec (`resources`, `affinity`, `tolerations`, `topologySpreadConstraints`, `containers`, `config` and similar) stay open. Every field accepts `null`. `cluster` itself accepts only `annotations`, `labels`, `spec`, `additionalSpec` and `additionalSpecString`.

**Who is affected:**

- Values that use only v0.9.0 fields are not affected. They render byte-identical to 0.6.0.
- Values with a CRD field newer than the chart. These used to pass through.
- Values with a typo at a level the operator owns. The API server used to prune the unknown key without a message.
- Values with a templated string on a field the schema types as integer, boolean or enum, such as `shards: "{{ .Values.extraValues.shards }}"`. Validation runs before `tpl`, so the schema sees the string.
- Releases upgraded with `helm upgrade --reuse-values`. Helm replaces the chart defaults with the values of the previous release, so `cluster.additionalSpec` is absent and the chart treats it as empty. Reused 0.6.0 values that use only v0.9.0 fields render unchanged. Helm also carries every key of the previous release into the new schema, so an unknown key from an earlier release fails the upgrade even when your values file no longer sets it. Run `helm get values <release>`, remove or move the key, and pass the result with `-f` (or use `--reset-then-reuse-values` with `--set` overrides).

**How to configure:** fix a typo in place. Move a field newer than the chart to `cluster.additionalSpec`:

```yaml
cluster:
  spec:
    shards: 3
  additionalSpec:
    someNewField: value
```

`additionalSpec` is deep-merged over `cluster.spec`. Maps merge, lists replace, and the escape hatch wins on conflict, including `false`, `0`, `""` and `[]`. A `null` deletes the key. The chart's own logic (the `replicasPerShard` default, `serviceAccountName`, the `usersSecret` checks) runs on the merged result.

To template a typed field, set it in `cluster.additionalSpecString`. It is rendered with `tpl` and parsed as YAML before the merge, so the result keeps its type:

```yaml
cluster:
  additionalSpecString: |
    shards: {{ .Values.extraValues.shards }}
```

The rendered spec then passes through `tpl` a second time with the rest of the spec, so a literal `{{` in `additionalSpecString` needs escaping twice.

## From 0.4.x

### Objects named after the release

**What changed:** the ValkeyCluster and the other objects the chart renders are named `<release>` instead of `<release>-valkey-resources`. The operator already prefixes what it creates with `valkey-`, so a release `cache` now gives the headless Service `valkey-cache` instead of `valkey-cache-valkey-resources`.

**Who is affected:** releases that do not set `fullnameOverride` and whose release name does not contain `valkey-resources` (or the `nameOverride` value, which 0.4.x used in place of the suffix). Aliased subchart copies keep their 0.4.x names and are not affected.

**How to configure:** before upgrading, set `fullnameOverride` to the current ValkeyCluster name to keep the cluster. Read it with `kubectl get valkeycluster -n <namespace>`; with default values it is `<release>-valkey-resources`:

```yaml
fullnameOverride: <release>-valkey-resources
```

Without it, the upgrade replaces the ValkeyCluster with a new, empty one under the new name and the old cluster's pods stop. With persistence and the default `reclaimPolicy: Retain`, the old PersistentVolumeClaims stay behind, but the new cluster does not use them. With `cluster.spec.persistence.reclaimPolicy: Delete`, removing the old ValkeyCluster also deletes its PersistentVolumeClaims, and the volumes behind them unless their StorageClass retains them: the data is gone. Check the policy, and take a backup, before upgrading a release without `fullnameOverride`. To move to the shorter name, create a new release and migrate the data to it.
