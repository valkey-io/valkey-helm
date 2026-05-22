{{/*
Expand the name of the chart.
*/}}
{{- define "valkey.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "valkey.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "valkey.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "valkey.labels" -}}
helm.sh/chart: {{ include "valkey.chart" . }}
{{ include "valkey.selectorLabels" . }}
{{- if or .Values.image.tag .Chart.AppVersion }}
app.kubernetes.io/version: {{ mustRegexReplaceAllLiteral "@sha.*" .Values.image.tag "" | default .Chart.AppVersion | trunc 63 | trimSuffix "-" | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "valkey.selectorLabels" -}}
app.kubernetes.io/name: {{ include "valkey.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "valkey.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "valkey.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Returns the Valkey container image
*/}}
{{- define "valkey.image" -}}
{{- include "common.image" (dict "image" (dict "registry" .Values.image.registry "repository" .Values.image.repository "tag" (.Values.image.tag | default .Chart.AppVersion)) "global" .Values.global) }}
{{- end -}}

{{/*
Returns the Valkey exporter container image
*/}}
{{- define "valkey.metrics.exporter.image" -}}
{{- include "common.image" (dict "image" .Values.metrics.exporter.image "global" .Values.global) }}
{{- end -}}

{{/*
The common image function that renders the container image
*/}}
{{- define "common.image" -}}
{{- $registryName := .image.registry -}}
{{- $repositoryName := .image.repository -}}
{{- $tag := .image.tag -}}
{{- if and .global .global.imageRegistry -}}
{{- $registryName = .global.imageRegistry -}}
{{- end -}}
{{- if $registryName -}}
{{- printf "%s/%s:%s" $registryName $repositoryName $tag -}}
{{- else -}}
{{- printf "%s:%s" $repositoryName $tag -}}
{{- end -}}
{{- end -}}

{{/*
Returns the Valkey image pull secrets
*/}}
{{- define "valkey.imagePullSecrets" -}}
{{- $pullSecrets := list }}
{{- if .Values.global }}
  {{- range .Values.global.imagePullSecrets -}}
    {{- $pullSecrets = append $pullSecrets . -}}
  {{- end -}}
{{- end -}}
{{- range .Values.imagePullSecrets -}}
    {{- $pullSecrets = append $pullSecrets . -}}
{{- end -}}
{{- if (not (empty $pullSecrets)) }}
imagePullSecrets:
{{- range $pullSecrets }}
- name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Check if there are any users with inline passwords
*/}}
{{- define "valkey.hasInlinePasswords" -}}
{{- $hasInlinePasswords := false -}}
{{- range $username, $user := .Values.auth.aclUsers -}}
  {{- if $user.password -}}
    {{- $hasInlinePasswords = true -}}
  {{- end -}}
{{- end -}}
{{- $hasInlinePasswords -}}
{{- end -}}

{{/*
Validate auth configuration
*/}}
{{- define "valkey.validateAuthConfig" -}}
{{- if .Values.auth.enabled }}
  {{- if not (or .Values.auth.aclUsers .Values.auth.aclConfig) }}
    {{- fail "auth.enabled is true but no authentication method is configured. Please provide auth.aclUsers or auth.aclConfig" }}
  {{- end }}
  {{- if .Values.auth.aclUsers }}
    {{- $hasUsersExistingSecret := .Values.auth.usersExistingSecret }}
    {{- if not (hasKey .Values.auth.aclUsers "default") }}
      {{- fail "The 'default' user must be defined in auth.aclUsers when authentication is enabled. Without it, anyone can access the database without credentials." }}
    {{- end }}
    {{- range $username, $user := .Values.auth.aclUsers }}
      {{- if not $user.permissions }}
        {{- fail (printf "User '%s' in auth.aclUsers must have a 'permissions' field" $username) }}
      {{- end }}
      {{- if not (or $user.password $hasUsersExistingSecret) }}
        {{- fail (printf "User '%s' must have either 'password' field or auth.usersExistingSecret must be set" $username) }}
      {{- end }}
      {{- if and $user.passwordKey (not $hasUsersExistingSecret) }}
        {{- fail (printf "User '%s' has passwordKey but auth.usersExistingSecret is not set" $username) }}
      {{- end }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Headless service name for replication
*/}}
{{- define "valkey.headlessServiceName" -}}
{{ include "valkey.fullname" . }}-headless
{{- end -}}

{{/*
Validate replica persistence configuration
*/}}
{{- define "valkey.validateReplicaPersistence" -}}
{{- if .Values.replica.enabled }}
  {{- if not .Values.replica.persistence.size }}
    {{- fail "Replica mode requires persistent storage. Please set replica.persistence.size (e.g., '5Gi')" }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Validate replica authentication configuration
*/}}
{{- define "valkey.validateReplicaAuth" -}}
{{- if and .Values.replica.enabled .Values.auth.enabled }}
  {{- if not (hasKey .Values.auth.aclUsers .Values.replica.replicationUser) }}
    {{- fail (printf "Replication user '%s' (replica.replicationUser) must be defined in auth.aclUsers. The chart requires this to retrieve the password for replica authentication." .Values.replica.replicationUser) }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Validate cluster configuration
*/}}
{{- define "valkey.validateClusterConfig" -}}
{{- if .Values.cluster.enabled }}
  {{- if .Values.replica.enabled }}
    {{- fail "cluster.enabled and replica.enabled are mutually exclusive. Please enable only one mode." }}
  {{- end }}
  {{- if lt (int .Values.cluster.shards) 3 }}
    {{- fail "Cluster mode requires at least 3 shards (cluster.shards >= 3) for proper cluster operation." }}
  {{- end }}
  {{- if not .Values.cluster.persistence.size }}
    {{- fail "Cluster mode requires persistent storage. Please set cluster.persistence.size (e.g., '5Gi')" }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Validate cluster authentication configuration
*/}}
{{- define "valkey.validateClusterAuth" -}}
{{- if and .Values.cluster.enabled .Values.auth.enabled }}
  {{- if not (hasKey .Values.auth.aclUsers .Values.cluster.replicationUser) }}
    {{- fail (printf "Cluster replication user '%s' (cluster.replicationUser) must be defined in auth.aclUsers. The chart requires this to retrieve the password for cluster authentication." .Values.cluster.replicationUser) }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Calculate total number of nodes in the cluster
*/}}
{{- define "valkey.clusterNodeCount" -}}
{{- $shards := int .Values.cluster.shards -}}
{{- $replicasPerShard := int .Values.cluster.replicasPerShard -}}
{{- mul $shards (add 1 $replicasPerShard) -}}
{{- end -}}

{{/*
Istio pod labels. Emits the labels that tell Istio exactly how to capture
this pod's traffic, so the chart works whether or not the namespace carries
`istio-injection=enabled` or `istio.io/dataplane-mode=ambient` — and, just
as importantly, so that toggling `istio.mode` on a dual-mode cluster moves
pods between data planes cleanly.

Sidecar mode:
  sidecar.istio.io/inject: "true"   — force Envoy injection even if the
                                       namespace lacks the injection label.
  istio.io/dataplane-mode: none     — veto ambient capture, so a cluster
                                       that ALSO runs ambient (e.g. during
                                       a sidecar→ambient migration) does
                                       not double-redirect this pod.

Ambient mode:
  istio.io/dataplane-mode: ambient  — ztunnel captures this pod's traffic.
  sidecar.istio.io/inject: "false"  — veto Envoy injection even if the
                                       namespace has the injection label,
                                       so the pod isn't simultaneously
                                       sidecar'd (which double-redirects
                                       and silently breaks mTLS, surfacing
                                       as "Connection reset by peer" on
                                       every request).

Either mode by itself is enough; emitting both (per mode) makes pod-level
intent the source of truth and eliminates the cluster-configuration
dependency that's easy to miss at install time.

When istio.enabled is false this helper emits nothing so the user remains
free to pick their own opt-in/out via podLabels (see the istio=off
functional-tests path).
*/}}
{{- define "valkey.istioPodLabels" -}}
{{- if .Values.istio.enabled -}}
{{- if eq (.Values.istio.mode | default "sidecar") "ambient" -}}
istio.io/dataplane-mode: ambient
sidecar.istio.io/inject: "false"
{{- else -}}
sidecar.istio.io/inject: "true"
istio.io/dataplane-mode: none
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Compute the merged pod labels map: selector + common + chart-computed mesh
labels + user podLabels (user wins on collision). Emits the merged dict as
YAML so the rendered output has no duplicate keys, even when a user sets
e.g. `sidecar.istio.io/inject=false` via podLabels alongside
`istio.enabled=true`.
*/}}
{{- define "valkey.podLabels" -}}
{{- $selector := fromYaml (include "valkey.selectorLabels" .) -}}
{{- $common   := .Values.commonLabels | default dict -}}
{{- $mesh     := fromYaml (include "valkey.istioPodLabels" .) | default dict -}}
{{- $user     := .Values.podLabels   | default dict -}}
{{- toYaml (mergeOverwrite $selector $common $mesh $user) -}}
{{- end -}}

{{/*
Job-pod labels: same merge as valkey.podLabels with one extra layer for
`cluster.initJob.podLabels` applied last (so it wins). Lets operators
veto a globally-injected metrics/observability sidecar on the cluster-
init Job — which is a short-lived, exit-on-success batch task — without
having to disable the same injector for the long-running data pods.
mergeOverwrite handles the deep-merge and the no-duplicate-keys
guarantee just like the data-pod helper.
*/}}
{{- define "valkey.initJobPodLabels" -}}
{{- $selector := fromYaml (include "valkey.selectorLabels" .) -}}
{{- $common   := .Values.commonLabels | default dict -}}
{{- $mesh     := fromYaml (include "valkey.istioPodLabels" .) | default dict -}}
{{- $user     := .Values.podLabels    | default dict -}}
{{- $jobUser  := (.Values.cluster.initJob).podLabels | default dict -}}
{{- toYaml (mergeOverwrite $selector $common $mesh $user $jobUser) -}}
{{- end -}}

{{/*
Job-pod annotations: same shape as the global .Values.podAnnotations,
with `cluster.initJob.podAnnotations` merged on top so it wins on
collision. Same opt-out rationale as valkey.initJobPodLabels — some
sidecar injectors read annotations rather than labels.

Emits nothing when the merged map is empty so the Job's metadata block
collapses cleanly (Helm/`with` semantics expect an absent key, not an
empty mapping, to skip).
*/}}
{{- define "valkey.initJobPodAnnotations" -}}
{{- $global := .Values.podAnnotations | default dict -}}
{{- $job    := (.Values.cluster.initJob).podAnnotations | default dict -}}
{{- $merged := mergeOverwrite (deepCopy $global) $job -}}
{{- if $merged -}}
{{- toYaml $merged -}}
{{- end -}}
{{- end -}}

{{/*
Probe shell command. Returns the "sh -c" argument that pings valkey-server
locally and accepts replies that prove the server is up AND serving.

Replies to PING are one of:
  PONG          — fully up, dataset loaded
  NOAUTH …      — up, requires auth (treat as proof of liveness — the
                  server is fully serving, we just lack credentials)
  LOADING …     — TCP listener is up but the dataset is still being read
                  from RDB/AOF; the server cannot serve traffic yet

LOADING is deliberately NOT accepted, including by startupProbe. The
whole reason startupProbe exists in Kubernetes (added in 1.16) is to
gate liveness/readiness behind a slow-startup window — that gate has
to actually fail during startup or the gate does nothing. With LOADING
accepted by startupProbe, the probe passes the moment the TCP listener
opens; kubelet switches immediately to livenessProbe (which does not
accept LOADING) and the pod gets killed during load anyway, just
attributed to liveness. Operators with multi-GB RDBs bump
`startupProbe.failureThreshold` instead — that is the canonical
Kubernetes pattern for slow loaders.
*/}}
{{- define "valkey.probeShellCommand" -}}
{{- $pingCmd := "valkey-cli ping" -}}
{{- if .Values.tls.enabled -}}
{{- $pingCmd = printf "valkey-cli --tls --cacert /tls/%s ping" .Values.tls.caPublicKey -}}
{{- end -}}
{{- printf "%s 2>&1 | grep -qE 'PONG|NOAUTH'" $pingCmd -}}
{{- end -}}

{{/*
The valkey ServiceAccount name as an Istio SPIFFE principal.
Used by the AuthorizationPolicy to pin the cluster-bus port to same-release
pods cryptographically rather than by pod-selector IP.
*/}}
{{- define "valkey.istioPrincipal" -}}
{{- $trustDomain := .Values.istio.trustDomain | default "cluster.local" -}}
{{- printf "%s/ns/%s/sa/%s" $trustDomain .Release.Namespace (include "valkey.serviceAccountName" .) -}}
{{- end -}}

{{/*
Validate istio configuration. Runs regardless of istio.enabled so a typo in
istio.mode (e.g. `mode: ambiet` buried in a GitOps values file) surfaces at
template time instead of silently rendering the sidecar-only code paths.
*/}}
{{- define "valkey.validateIstioConfig" -}}
{{- if hasKey .Values.istio "mode" }}
  {{- if not (or (eq .Values.istio.mode "sidecar") (eq .Values.istio.mode "ambient")) }}
    {{- fail (printf "istio.mode must be 'sidecar' or 'ambient', got: %s" .Values.istio.mode) }}
  {{- end }}
{{- end }}
{{- /*
Guard against the silent-no-protection footgun for the cluster bus port:
when istio is enabled in ambient mode AND cluster mode is on, dropping BOTH
the NetworkPolicy (skipped for ambient) AND the AuthorizationPolicy leaves
the bus port open to any pod that can route to it. The feature's whole
point is cross-release isolation; failing closed is the only safe default.
Users who genuinely want the bus port unprotected can set
`cluster.isolation.enabled=true` (NetworkPolicy path still runs in sidecar
mode, but in ambient it's dropped) and explicitly acknowledge by setting
`istio.authorizationPolicy.enabled=true`; the chart refuses to let BOTH be
false when both layers have been chosen-off.
*/}}
{{- if and .Values.istio.enabled (eq .Values.istio.mode "ambient") .Values.cluster.enabled }}
  {{- if not .Values.istio.authorizationPolicy.enabled }}
    {{- fail "istio.authorizationPolicy.enabled=false in ambient mode + cluster mode leaves the cluster-bus port unprotected: the NetworkPolicy is skipped for ambient (it would block HBONE), and disabling the AuthorizationPolicy removes the only remaining cross-release isolation layer. Re-enable istio.authorizationPolicy.enabled, or switch to istio.mode=sidecar if you intend to rely on the NetworkPolicy." }}
  {{- end }}
{{- end }}
{{- /*
Guard against the shared-ServiceAccount footgun. The AuthorizationPolicy
uses the SPIFFE principal `<trust-domain>/ns/<ns>/sa/<sa>` to scope the bus
port to same-release pods. If two releases in the same namespace share a SA
(e.g. both use `serviceAccount.create=false` with the namespace default, or
both explicitly set the same `serviceAccount.name`), their APs encode the
SAME principal — cross-release MEET passes the identity check and the
clusters silently merge. The chart cannot detect other releases at template
time, but it can surface the risk: refuse the obviously-unsafe case
(`serviceAccount.create=false` with no explicit name, i.e. the shared
`default` SA) whenever the AP is rendered. Users who deliberately share
a named SA across releases can still do so; they just have to type it.
*/}}
{{- if and .Values.istio.enabled .Values.istio.authorizationPolicy.enabled .Values.cluster.enabled }}
  {{- if and (not .Values.serviceAccount.create) (not .Values.serviceAccount.name) }}
    {{- fail "istio.authorizationPolicy gives cross-release cluster-bus isolation by scoping the bus port to a SPIFFE principal built from the pod's ServiceAccount. With serviceAccount.create=false AND serviceAccount.name empty, the chart falls back to the namespace's 'default' ServiceAccount — which every other release using the same fallback ALSO maps to, so the AuthorizationPolicy cannot distinguish them and cross-release CLUSTER MEET succeeds. Either set serviceAccount.create=true (per-release SA) or serviceAccount.name=<distinct-name>." }}
  {{- end }}
{{- end }}
{{- end -}}


