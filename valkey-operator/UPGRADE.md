# Upgrade

## From 0.8.x to 0.9.0

This version updates the CRDs to match the valkey-operator release bundled in this chart.
Helm does not upgrade CRDs during `helm upgrade`, so you must apply them manually before upgrading.
The v0.9 operator records the ACL revision each Valkey node has loaded in the ValkeyNode status. The v0.8 ValkeyNode CRD does not have that field, so the API server drops it and the operator runs `ACL LOAD` on every Valkey node about every 30 seconds. The old CRD also drops `networking.perNodeServices` from each ValkeyNode: the ValkeyCluster accepts the field, but no per-node Service is created.

Run these commands to update the CRDs before applying the upgrade. `--force-conflicts` is needed because Helm owns the CRD fields it installed:

```console
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.9.0/config/crd/bases/valkey.io_valkeyclusters.yaml
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.9.0/config/crd/bases/valkey.io_valkeynodes.yaml
```

Before upgrading the chart, check two things:

- The upgrade turns the Valkey `default` user off on every cluster that does not declare it, and closes the connections logged in as `default`, which includes clients that never authenticate. To keep an open `default`, declare it in each ValkeyCluster's `spec.users` first. The [release notes](https://github.com/valkey-io/valkey-operator/releases/tag/v0.9.0) have the snippet.
- If your values set `image.tag`, remove it or set it to v0.9.0 or later. The chart now passes `--default-valkey-image` and `--default-exporter-image`, and an older operator exits on flags it does not know.

Then upgrade the chart:

```console
helm upgrade <release-name> valkey/valkey-operator --version 0.9.0
```

If the CRDs are applied after the chart upgrade, restart the operator Deployment afterwards. An operator that was running when the CRDs changed does not create per-node Services until it restarts.

The upgrade rolls every ValkeyCluster once, one node at a time.

The operator now requires `--default-valkey-image` and `--default-exporter-image`. The chart passes both from `manager.defaultImages`, set to the images v0.8 had built in. If you maintain your own operator Deployment, add both flags or the operator exits at startup.

`spec.users` and `spec.replicas` are deprecated in favour of `spec.acl.users` and `spec.replicasPerShard`. They still work, and a ValkeyCluster that uses one reports a `ConfigurationWarning` condition. Move a cluster to the new fields only after this upgrade, once the new CRDs are applied and the v0.8 operator pod is gone: a v0.8 operator reads 0 replicas from a cluster that only sets `replicasPerShard` and deletes its replicas. See the [release notes](https://github.com/valkey-io/valkey-operator/releases/tag/v0.9.0) for details.

## From 0.7.x to 0.8.0

This version updates the CRDs to match the valkey-operator release bundled in this chart.
Helm does not upgrade CRDs during `helm upgrade`, so you must apply them manually before upgrading.
The v0.8 operator copies the new `podMetadata` and `serviceAccountName` fields from each ValkeyCluster to its ValkeyNodes. The v0.7 ValkeyNode CRD does not have them, so the API server drops them: the cluster reports `Ready`, but the labels and annotations never reach the pods and the pods keep the namespace's default ServiceAccount.

Run these commands to update the CRDs before applying the upgrade. `--force-conflicts` is needed because Helm owns the CRD fields it installed:

```console
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.8.0/config/crd/bases/valkey.io_valkeyclusters.yaml
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.8.0/config/crd/bases/valkey.io_valkeynodes.yaml
```

Then upgrade the chart:

```console
helm upgrade <release-name> valkey/valkey-operator --version 0.8.0
```

The upgrade does not roll Valkey pods. A ValkeyCluster created before v0.8.0 whose name is longer than the new limit (41 characters for `workloadType: StatefulSet`) can no longer be updated. See the [release notes](https://github.com/valkey-io/valkey-operator/releases/tag/v0.8.0) for details.

## From 0.6.x to 0.7.0

This version updates the CRDs to match the valkey-operator release bundled in this chart.
Helm does not upgrade CRDs during `helm upgrade`, so you must apply them manually before upgrading.
The v0.7 operator writes fields to each ValkeyNode that the v0.6.0 CRDs do not have. If the CRDs are not updated first, the operator updates the same ValkeyNode on every reconcile and the cluster stays in `Reconciling/UpdatingNodes`.

Run these commands to update the CRDs before applying the upgrade. `--force-conflicts` is needed because Helm owns the CRD fields it installed:

```console
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.7.1/config/crd/bases/valkey.io_valkeyclusters.yaml
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.7.1/config/crd/bases/valkey.io_valkeynodes.yaml
```

Then upgrade the chart:

```console
helm upgrade <release-name> valkey/valkey-operator --version 0.7.0
```

The upgrade rolls every ValkeyCluster once, one node at a time, and `cluster-node-timeout` moves from 2000 ms to the Valkey default of 15000 ms unless it is set in `spec.config`. See the [release notes](https://github.com/valkey-io/valkey-operator/releases/tag/v0.7.0) for details.

## From 0.5.x to 0.6.0

There are breaking changes in `ValkeyCluster` migrating from `spec.networking.tls.certificate` to `spec.networking.tls.certificates.server`. See the [release notes](https://github.com/valkey-io/valkey-operator/releases/tag/v0.6.0) for steps on how to mitigate them.

This version updates the CRDs to match the valkey-operator release bundled in this chart.
Helm does not upgrade CRDs during `helm upgrade`, so you must apply them manually before upgrading.

Run these commands to update the CRDs before applying the upgrade:

```console
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.6.0/config/crd/bases/valkey.io_valkeyclusters.yaml
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.6.0/config/crd/bases/valkey.io_valkeynodes.yaml
```

Then upgrade the chart:

```console
helm upgrade <release-name> valkey/valkey-operator --version 0.6.0
```

## From 0.4.x to 0.5.0

There are breaking changes in `ValkeyCluster` migrating from `spec.tls` to `spec.networking.tls`. See the [release notes](https://github.com/valkey-io/valkey-operator/releases/tag/v0.5.0) for steps on how to mitigate them.

This version updates the CRDs to match the valkey-operator release bundled in this chart.
Helm does not upgrade CRDs during `helm upgrade`, so you must apply them manually before upgrading.

Run these commands to update the CRDs before applying the upgrade:

```console
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.5.0/config/crd/bases/valkey.io_valkeyclusters.yaml
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.5.0/config/crd/bases/valkey.io_valkeynodes.yaml
```

Then upgrade the chart:

```console
helm upgrade <release-name> valkey/valkey-operator --version 0.5.0
```

## From 0.3.x to 0.4.0

This version updates the CRDs to match the valkey-operator release bundled in this chart.
Helm does not upgrade CRDs during `helm upgrade`, so you must apply them manually before upgrading.

Run these commands to update the CRDs before applying the upgrade:

```console
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.4.0/config/crd/bases/valkey.io_valkeyclusters.yaml
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.4.0/config/crd/bases/valkey.io_valkeynodes.yaml
```

Then upgrade the chart:

```console
helm upgrade <release-name> valkey/valkey-operator --version 0.4.0
```

## From 0.2.x to 0.3.0

This version updates the CRDs to match the valkey-operator release bundled in this chart.
Helm does not upgrade CRDs during `helm upgrade`, so you must apply them manually before upgrading.

Run these commands to update the CRDs before applying the upgrade:

```console
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.3.0/config/crd/bases/valkey.io_valkeyclusters.yaml
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.3.0/config/crd/bases/valkey.io_valkeynodes.yaml
```

Then upgrade the chart:

```console
helm upgrade <release-name> valkey/valkey-operator --version 0.3.0
```

## From 0.1.x to 0.2.0

This version updates the CRDs to match the valkey-operator release bundled in this chart.
Helm does not upgrade CRDs during `helm upgrade`, so you must apply them manually before upgrading.

Run these commands to update the CRDs before applying the upgrade:

```console
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.2.0/config/crd/bases/valkey.io_valkeyclusters.yaml
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.2.0/config/crd/bases/valkey.io_valkeynodes.yaml
```

Then upgrade the chart:

```console
helm upgrade <release-name> valkey/valkey-operator --version 0.2.0
```
