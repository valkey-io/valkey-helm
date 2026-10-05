# Upgrading the valkey chart

## 0.x to 1.0

### Standalone `deploymentStrategy` defaults to `Recreate`

**What changed:** the standalone Deployment now stops the old pod before starting the new one, because a rolling update cannot hand a ReadWriteOnce volume over to the new pod. Upgrades have a short downtime.

**Who is affected:** standalone releases (`replica.enabled: false`) that do not set `deploymentStrategy`.

**How to configure:** no action needed. Without persistence, set `deploymentStrategy: RollingUpdate` to keep upgrades without downtime. If the release is applied with server-side apply (e.g. Argo CD `ServerSideApply=true`), run `kubectl patch deployment <release>-valkey -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'` before upgrading.

---

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

---

### Configuration: `valkeyConfig` renamed to `extraConfig`

**What changed:** the raw configuration appended to `valkey.conf` is now `extraConfig`, and is rendered as a template.

**Who is affected:** releases that set `valkeyConfig`.

**How to configure:** rename `valkeyConfig` to `extraConfig`.

---

### Secret and ConfigMap mount shortcuts removed

**What changed:** files are mounted only through `extraVolumes` plus `extraVolumeMounts` (Valkey container) or `metrics.exporter.extraVolumeMounts` (exporter). The chart's init container no longer receives `extraVolumeMounts`.

**Who is affected:** releases that set `extraValkeySecrets`, `extraValkeyConfigs`, `extraSecretValkeyConfigs` or `metrics.exporter.extraExporterSecrets`.

**How to configure:**

- `extraValkeySecrets` / `extraValkeyConfigs`: add a `secret` / `configMap` volume to `extraVolumes` and mount it with `extraVolumeMounts`.
- `extraSecretValkeyConfigs`: drop it and the `extravalkeyconfigs-volume` entries; mount the files as above and load them with `include <path>` in `extraConfig`.
- `metrics.exporter.extraExporterSecrets`: add the `secret` volume to `extraVolumes` and mount it with `metrics.exporter.extraVolumeMounts`.

### `env` and `metrics.exporter.extraEnvs` replaced by `extraEnv` lists

**What changed:** environment variables are Kubernetes EnvVar lists, which also accept `valueFrom`.

**Who is affected:** releases that set `env` or `metrics.exporter.extraEnvs`.

**How to configure:** turn each `NAME: value` entry into `- name: NAME` / `value: "value"` under `extraEnv` (Valkey) or `metrics.exporter.extraEnv` (exporter). Quote numbers and booleans, Kubernetes only accepts strings.

---

### Metrics `extraLabels` and `extraAnnotations` renamed

**What changed:** the metrics Service, ServiceMonitor, PodMonitor and PrometheusRule take `labels` and `annotations`, like the rest of the chart.

**Who is affected:** releases that set `metrics.service.extraLabels`, `metrics.serviceMonitor.extraLabels`, `metrics.podMonitor.extraLabels`, `metrics.prometheusRule.extraLabels` or `metrics.prometheusRule.extraAnnotations`.

**How to configure:** rename `extraLabels` to `labels` and `extraAnnotations` to `annotations`.
