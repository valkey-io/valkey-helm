# Upgrade

## From 0.2.x to 0.3.0

This version updates the CRDs to match the valkey-operator release bundled in this chart.
Helm does not upgrade CRDs during `helm upgrade`, so you must apply them manually before upgrading.

Run these commands to update the CRDs before applying the upgrade:

```console
kubectl apply --server-side -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.3.0/config/crd/bases/valkey.io_valkeyclusters.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.3.0/config/crd/bases/valkey.io_valkeynodes.yaml
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
kubectl apply --server-side -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.2.0/config/crd/bases/valkey.io_valkeyclusters.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/valkey-io/valkey-operator/v0.2.0/config/crd/bases/valkey.io_valkeynodes.yaml
```

Then upgrade the chart:

```console
helm upgrade <release-name> valkey/valkey-operator --version 0.2.0
```
