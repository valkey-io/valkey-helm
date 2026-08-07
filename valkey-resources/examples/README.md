# valkey-resources examples

Helm values overlays for common `ValkeyCluster` shapes (operator **v0.4.0+**).

Each file is meant for `helm install` / `helm upgrade` with `-f`. Merge multiple files when needed.

From a git checkout:

```bash
helm install my-cluster ./valkey-resources -n valkey \
  -f valkey-resources/examples/minimal.yaml \
  -f valkey-resources/examples/scheduling-node-spread.yaml
```

From the published chart (copy examples from the repo or pin a path):

```bash
helm install my-cluster valkey/valkey-resources -n valkey \
  -f scheduling-node-spread.yaml
```

## Files

| File | What it shows |
|---|---|
| [minimal.yaml](minimal.yaml) | Explicit shards / replicas only |
| [scheduling-node-spread.yaml](scheduling-node-spread.yaml) | `scheduling.node.spread` (shard-aware node HA) + PDB |
| [scheduling-zone-spread.yaml](scheduling-zone-spread.yaml) | Zone `topologySpreadConstraints` escape hatch |
| [tls.yaml](tls.yaml) | TLS Secret ref via `extraValues` + `tpl` |
| [persistence.yaml](persistence.yaml) | PVC size on StatefulSet |
| [metrics-podmonitor.yaml](metrics-podmonitor.yaml) | PodMonitor for exporter sidecars |
| [users-acl.yaml](users-acl.yaml) | ACL users with password Secret refs |

## Notes

- Chart defaults leave `node.spread` off (operator default `Disabled`). Production clusters should set `shard` to at least `Preferred`; see `scheduling-node-spread.yaml`.
- Prefer `node.spread` for hostname / node anti-colocation. Use raw `topologySpreadConstraints` for other keys (for example zones). Do not stack a hostname TSC with `node.spread.primaries` / `pods` at the same strength.
- Secrets are references only; create them out of band.
- CRDs come from the `valkey-operator` chart. Helm does not upgrade CRDs automatically.

## Follow-up

More examples and helm unittest render smoke tests for this directory are planned; this set is the first cut.
