# Upgrade

## From 0.6.x to 0.7.0

This version requires Kubernetes 1.32 or newer.

This version updates the CRDs to match the valkey-operator release bundled in this chart.
Helm does not upgrade CRDs during `helm upgrade`, so you must apply them manually before upgrading.
The v0.7.0 operator writes fields to each ValkeyNode that the v0.6.0 CRDs do not have. If the CRDs are not updated first, the operator updates the same ValkeyNode on every reconcile and the cluster stays in `Reconciling/UpdatingNodes`.

Run these commands to update the CRDs before applying the upgrade. `--force-conflicts` is needed because Helm owns the CRD fields it installed:

```console
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.7.0/config/crd/bases/valkey.io_valkeyclusters.yaml
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.7.0/config/crd/bases/valkey.io_valkeynodes.yaml
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
