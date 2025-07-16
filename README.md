# valkey-helm
Valkey Helm Chart

## Prerequisites

- Kubernetes 1.30+
- Helm 3.x
- PV provisioner support in the underlying infrastructure


## Installing the Chart

To install the chart with the release name `my-release`:

```bash
helm install my-release valkey
```

## Uninstalling the Chart

To uninstall/delete the `my-release` deployment:

```bash
helm uninstall my-release
