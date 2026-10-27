# Upgrading the valkey-resources chart

## From 0.4.x

### Objects named after the release

**What changed:** the ValkeyCluster and the other objects the chart renders are named `<release>` instead of `<release>-valkey-resources`. The operator already prefixes what it creates with `valkey-`, so a release `cache` now gives the headless Service `valkey-cache` instead of `valkey-cache-valkey-resources`.

**Who is affected:** releases that do not set `fullnameOverride` and whose release name does not contain `valkey-resources` (or the `nameOverride` value, which 0.4.x used in place of the suffix). Aliased subchart copies without `nameOverride` keep `<release>-<alias>`.

**How to configure:** before upgrading, set `fullnameOverride` to the current ValkeyCluster name to keep the cluster. Read it with `kubectl get valkeycluster -n <namespace>`; with default values it is `<release>-valkey-resources`:

```yaml
fullnameOverride: <release>-valkey-resources
```

Without it, the upgrade replaces the ValkeyCluster with a new, empty one under the new name and the old cluster's pods stop. With persistence and the default `reclaimPolicy: Retain`, the old PersistentVolumeClaims stay behind, but the new cluster does not use them. With `cluster.spec.persistence.reclaimPolicy: Delete`, removing the old ValkeyCluster also deletes its PersistentVolumeClaims, and the volumes behind them unless their StorageClass retains them: the data is gone. Check the policy, and take a backup, before upgrading a release without `fullnameOverride`. To move to the shorter name, create a new release and migrate the data to it.
