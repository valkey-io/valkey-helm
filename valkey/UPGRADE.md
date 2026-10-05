# Upgrading the valkey chart

## 0.x to 1.0

### Standalone `deploymentStrategy` defaults to `Recreate`

**What changed:** the standalone Deployment now stops the old pod before starting the new one, because a rolling update cannot hand a ReadWriteOnce volume over to the new pod. Upgrades have a short downtime.

**Who is affected:** standalone releases (`replica.enabled: false`) that do not set `deploymentStrategy`.

**How to configure:** no action needed. Without persistence, set `deploymentStrategy: RollingUpdate` to keep upgrades without downtime. If the release is applied with server-side apply (e.g. Argo CD `ServerSideApply=true`), run `kubectl patch deployment <release>-valkey -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'` before upgrading.

### Storage: `dataStorage` and `replica.persistence` replaced by `persistence`

**What changed:** one `persistence` block configures storage in both modes. PVC names do not change, so existing data is kept. The chart refuses to render while the old keys are set.

**Who is affected:** releases that set `dataStorage.*` (standalone) or `replica.persistence.*` (replication).

**How to configure:** move the values to `persistence`.

Standalone, from `dataStorage`:

- `requestedSize` → `persistence.size`.
- `className` → `persistence.storageClass`.
- `persistentVolumeClaimName` → `persistence.existingClaim`.
- `keepPvc` → `persistence.keepOnUninstall`.
- `volumeName` is removed; the volume is always `valkey-data`.

Replication, from `replica.persistence`: move the block to the top level as `persistence` (`size`, `storageClass` and `accessModes` keep their names) and add `enabled: true`.
