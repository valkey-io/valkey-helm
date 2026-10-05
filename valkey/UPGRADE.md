# Upgrading the valkey chart

## 0.x to 1.0

Upgrade with your complete, migrated values file, without `--reuse-values` or `--reset-then-reuse-values`. Both carry over the previous release's values, removed keys included, which the chart refuses; `--reuse-values` also replaces the new chart's defaults with the 0.x ones, so the upgrade fails on missing values.

### Valkey 9.0 or later required

**What changed:** the chart requires Valkey 9.0 or later. It uses Sentinel's coordinated failover, which Valkey added in 9.0.

**Who is affected:** releases that pin `image.tag` to an 8.x or older version.

**How to configure:** set `image.tag` to a 9.x version, or remove it to use the chart's default.

---

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

- `enabled` → `persistence.enabled`. Set it to `true` also when using `persistentVolumeClaimName` or `hostPath`: 0.x mounted them even with `enabled: false`, 1.0 refuses to render that.
- `requestedSize` → `persistence.size`.
- `className` → `persistence.storageClass`.
- `persistentVolumeClaimName` → `persistence.existingClaim`.
- `keepPvc` → `persistence.keepOnUninstall`.
- `accessModes`, `subPath`, `hostPath`, `labels` and `annotations` keep their names.
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

---

### `env` and `metrics.exporter.extraEnvs` replaced by `extraEnv` lists

**What changed:** environment variables are Kubernetes EnvVar lists, which also accept `valueFrom`.

**Who is affected:** releases that set `env` or `metrics.exporter.extraEnvs`.

**How to configure:** turn each `NAME: value` entry into `- name: NAME` / `value: "value"` under `extraEnv` (Valkey) or `metrics.exporter.extraEnv` (exporter). Quote numbers and booleans, Kubernetes only accepts strings.

---

### Metrics `extraLabels` and `extraAnnotations` renamed

**What changed:** the metrics Service, ServiceMonitor, PodMonitor and PrometheusRule take `labels` and `annotations`, like the rest of the chart.

**Who is affected:** releases that set `metrics.service.extraLabels`, `metrics.serviceMonitor.extraLabels`, `metrics.podMonitor.extraLabels`, `metrics.prometheusRule.extraLabels` or `metrics.prometheusRule.extraAnnotations`.

**How to configure:** rename `extraLabels` to `labels` and `extraAnnotations` to `annotations`.

---

### Metrics exporter hardened by default

**What changed:** `metrics.exporter.securityContext` defaults to `allowPrivilegeEscalation: false`, all capabilities dropped, a read-only root filesystem and `runAsNonRoot: true`, so pods with metrics enabled pass the restricted Pod Security Standard.

**Who is affected:** releases with `metrics.enabled: true`, in particular those using a custom exporter image.

**How to configure:** no action needed for the default exporter image. Values set under `metrics.exporter.securityContext` are merged onto the defaults; set it to `null` for an image that needs to write to its filesystem or run as root.

---

### Replication: `replica.replicas` counts the master too

**What changed:** `replica.replicas` is the number of Valkey pods, the master included (default `3`, the same three pods as before). `1` runs a master alone; Sentinel needs at least `2`.

**Who is affected:** replication releases that set `replica.replicas`. Left unchanged, the StatefulSet loses one pod on upgrade: the replica with the highest index is removed (its PVC is kept), and a `replica.minReplicasToWrite` that counted on it can make the master refuse writes.

**How to configure:** add 1 to `replica.replicas`, e.g. `2` becomes `3`.

---

### Mounts on the chart's own paths are refused

**What changed:** `extraVolumeMounts`, `metrics.exporter.extraVolumeMounts` and `haproxy.extraVolumeMounts` may not mount on, or below, a path the chart mounts itself, such as `/data` or `/tls`. The exporter now gets the TLS files from the chart.

**Who is affected:** releases that mounted the TLS Secret into the exporter at `/tls` themselves, or mount anything on a chart path.

**How to configure:** remove the exporter's `/tls` mount. Move other mounts to a path of their own; TLS files that are not in `tls.existingSecret` go into `tls.volume`.

---

### `networkPolicy` is a structured block

**What changed:** the NetworkPolicy is created only with `networkPolicy.enabled: true` and is built from options; `networkPolicy.ingress` and `networkPolicy.egress` are replaced by `extraIngress` and `extraEgress`, which add rules on top of the chart's own. The chart refuses to render while the old keys are set.

**Who is affected:** releases that set `networkPolicy`.

**How to configure:**

- `ingress` → `networkPolicy.extraIngress`, with `enabled: true` and `allowExternal: false`. With `allowExternal: true` the chart's rule admits every client on the Valkey port, whatever your rules say.
- `egress` → `networkPolicy.extraEgress`, with `enabled: true` and `allowExternalEgress: false`. DNS and the other Valkey pods are then allowed by the chart.
- `labels` and `annotations` keep their names; set `enabled: true` to keep the policy.

---

### Fixed container names in the Valkey pods

**What changed:** the Valkey pods' containers are named `valkey`, `init` and `metrics` instead of `<fullname>` and `<fullname>-init`. The pods and their workload are also labelled `app.kubernetes.io/component: valkey` (not part of the selectors). The pods restart once on upgrade.

**Who is affected:** scripts and tools that address the containers by name, e.g. `kubectl exec -c` or `kubectl logs -c`.

**How to configure:** use `-c valkey`, `-c init` or `-c metrics`.
