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
{{- include "valkey.versionLabel" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end }}

{{/*
The app.kubernetes.io/version label, the Valkey version being deployed,
shared by every resource of the release (with a leading newline)
*/}}
{{- define "valkey.versionLabel" -}}
{{- if or .Values.image.tag .Chart.AppVersion }}
app.kubernetes.io/version: {{ mustRegexReplaceAllLiteral "@sha.*" .Values.image.tag "" | default .Chart.AppVersion | trunc 63 | trimSuffix "-" | quote }}
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
{{- include "valkey.common.image" (dict "image" (dict "registry" .Values.image.registry "repository" .Values.image.repository "tag" (.Values.image.tag | default .Chart.AppVersion)) "global" .Values.global) }}
{{- end -}}

{{/*
Returns the Valkey exporter container image
*/}}
{{- define "valkey.metrics.exporter.image" -}}
{{- $_ := required "metrics.exporter.image.tag must not be empty: set it to an exporter version, e.g. the chart's default in values.yaml" .Values.metrics.exporter.image.tag -}}
{{- include "valkey.common.image" (dict "image" .Values.metrics.exporter.image "global" .Values.global) }}
{{- end -}}

{{/*
The common image function that renders the container image
*/}}
{{- define "valkey.common.image" -}}
{{- $registryName := .image.registry }}
{{- $repositoryName := .image.repository }}
{{- $tag := .image.tag }}
{{- if .global }}
  {{- if .global.imageRegistry }}
    {{- $registryName = .global.imageRegistry }}
  {{- end }}
{{- end }}
{{- if $registryName }}
{{- printf "%s/%s:%s" $registryName $repositoryName $tag }}
{{- else }}
{{- printf "%s:%s" $repositoryName $tag }}
{{ end }}
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
{{- if and .Values.replica.enabled .Values.sentinel.enabled .Values.sentinel.password -}}
  {{- $hasInlinePasswords = true -}}
{{- end -}}
{{- $hasInlinePasswords -}}
{{- end -}}

{{/*
Whether the chart renders its own auth Secret: for inline user passwords or
auth.aclConfig when authentication is enabled, and for the inline Sentinel
password, which Sentinel needs whether or not authentication is enabled.
Returns "true" or "false".
*/}}
{{- define "valkey.renderAuthSecret" -}}
{{- $userSecret := and .Values.auth.enabled (or (include "valkey.hasInlinePasswords" . | eq "true") .Values.auth.aclConfig) -}}
{{- $sentinelSecret := and .Values.replica.enabled .Values.sentinel.enabled .Values.sentinel.password -}}
{{- if or $userSecret $sentinelSecret -}}
true
{{- else -}}
false
{{- end -}}
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
{{ include "valkey.fullnameWithSuffix" (list . "headless") }}
{{- end -}}

{{/*
The full name with "-<suffix>" appended, the full name shortened first so
that the result still fits the 63 characters allowed for Service, container
and volume names. Names that already fit come out unchanged. Only for names
with that limit: ConfigMaps, Secrets, Deployments and the like allow 253
characters and keep the plain "<fullname>-<suffix>".
Usage: include "valkey.fullnameWithSuffix" (list . "read")
*/}}
{{- define "valkey.fullnameWithSuffix" -}}
{{- $root := index . 0 -}}
{{- $suffix := index . 1 -}}
{{- printf "%s-%s" (include "valkey.fullname" $root | trunc (int (sub 62 (len $suffix))) | trimSuffix "-") $suffix -}}
{{- end -}}

{{/*
Stable names and selectors for the independent Sentinel StatefulSet.
*/}}
{{/*
StatefulSet names are kept to 52 characters: Kubernetes labels every pod with
controller-revision-hash: <statefulset name>-<10 character hash>, and a label
value longer than 63 characters makes every pod creation fail. The pods'
names, and so their DNS names, follow the StatefulSet name.
*/}}
{{- define "valkey.statefulsetName" -}}
{{- include "valkey.fullname" . | trunc 52 | trimSuffix "-" -}}
{{- end -}}

{{/*
Name of the Sentinel StatefulSet, Service and PodDisruptionBudget, 52
characters at most for the same reason.
*/}}
{{- define "valkey.sentinel.fullname" -}}
{{- printf "%s-sentinel" (include "valkey.fullname" . | trunc 43 | trimSuffix "-") -}}
{{- end -}}

{{/*
The Sentinel password, as the single file /sentinel-auth/password. Mounted by
the Sentinel pods and by the Valkey pods, which ask Sentinel for the master
on startup and for a failover before shutting down. The Valkey server itself
never uses it. Not optional: a missing Secret or key keeps the pod from
starting, with the reason in its events, rather than leaving it without one.
*/}}
{{- define "valkey.sentinel.authVolume" -}}
- name: sentinel-auth
  secret:
    {{- if .Values.sentinel.existingSecret }}
    secretName: {{ tpl .Values.sentinel.existingSecret . }}
    {{- else }}
    secretName: {{ include "valkey.fullname" . }}-auth
    {{- end }}
    defaultMode: 0400
    items:
      - key: {{ ternary .Values.sentinel.passwordKey "sentinel-password" (not (empty .Values.sentinel.existingSecret)) }}
        path: password
{{- end -}}

{{/*
Label that admits a pod to the Valkey port when networkPolicy.allowExternal is
false. A label name is limited to 63 characters, so the fullname is shortened
to leave room for the suffix.
*/}}
{{- define "valkey.networkPolicy.clientLabel" -}}
{{- printf "%s-client" (include "valkey.fullname" . | trunc 56 | trimSuffix "-") -}}
{{- end -}}

{{- define "valkey.sentinel.headlessServiceName" -}}
{{- /* Shortening "<fullname>-sentinel" first could cut "-sentinel" off
       entirely and collide with the Valkey headless service */}}
{{- include "valkey.fullnameWithSuffix" (list . "sentinel-hl") -}}
{{- end -}}

{{/*
Labels for the Sentinel resources, matching the Sentinel pods' name.
*/}}
{{- define "valkey.sentinel.labels" -}}
helm.sh/chart: {{ include "valkey.chart" . }}
{{ include "valkey.sentinel.selectorLabels" . }}
{{- include "valkey.versionLabel" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end -}}

{{- define "valkey.sentinel.selectorLabels" -}}
app.kubernetes.io/name: {{ printf "%s-sentinel" (include "valkey.name" . | trunc 54 | trimSuffix "-") }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: sentinel
{{- end -}}

{{/*
Refuse values that were removed or renamed in 1.0. Ignoring them would drop
settings silently, and for persistence it would cost the data: a standalone
release that still sets dataStorage.enabled would render without its PVC, so
Helm would delete the claim and the pod would start on an empty volume.
*/}}
{{- define "valkey.validateRemovedValues" -}}
{{- $removed := list
  (list "dataStorage" "dataStorage was replaced by persistence (dataStorage.requestedSize is now persistence.size, className is storageClass, persistentVolumeClaimName is existingClaim, keepPvc is keepOnUninstall). The PVC name does not change.")
  (list "replica.persistence" "replica.persistence was replaced by persistence: set persistence.enabled=true and move size, storageClass and accessModes there. The PVC names do not change.")
  (list "valkeyConfig" "valkeyConfig was renamed to extraConfig.")
  (list "extraValkeySecrets" "extraValkeySecrets was removed: add a secret volume to extraVolumes and mount it with extraVolumeMounts.")
  (list "extraValkeyConfigs" "extraValkeyConfigs was removed: add a configMap volume to extraVolumes and mount it with extraVolumeMounts.")
  (list "extraSecretValkeyConfigs" "extraSecretValkeyConfigs was removed: mount the files with extraVolumes and extraVolumeMounts, and load them with include <path> in extraConfig.")
  (list "env" "env was replaced by extraEnv, a list of Kubernetes EnvVar entries (name, value or valueFrom).")
  (list "metrics.exporter.extraEnvs" "metrics.exporter.extraEnvs was replaced by metrics.exporter.extraEnv, a list of Kubernetes EnvVar entries (name, value or valueFrom).")
  (list "metrics.exporter.extraExporterSecrets" "metrics.exporter.extraExporterSecrets was removed: add a secret volume to extraVolumes and mount it with metrics.exporter.extraVolumeMounts.")
  (list "metrics.service.extraLabels" "metrics.service.extraLabels was renamed to metrics.service.labels.")
  (list "metrics.serviceMonitor.extraLabels" "metrics.serviceMonitor.extraLabels was renamed to metrics.serviceMonitor.labels.")
  (list "metrics.podMonitor.extraLabels" "metrics.podMonitor.extraLabels was renamed to metrics.podMonitor.labels.")
  (list "metrics.prometheusRule.extraLabels" "metrics.prometheusRule.extraLabels was renamed to metrics.prometheusRule.labels.")
  (list "metrics.prometheusRule.extraAnnotations" "metrics.prometheusRule.extraAnnotations was renamed to metrics.prometheusRule.annotations.")
  (list "networkPolicy.ingress" "networkPolicy.ingress was replaced by networkPolicy.extraIngress: set networkPolicy.enabled=true and networkPolicy.allowExternal=false, otherwise the policy also admits every client on the Valkey port.")
  (list "networkPolicy.egress" "networkPolicy.egress was replaced by networkPolicy.extraEgress: set networkPolicy.enabled=true and networkPolicy.allowExternalEgress=false, otherwise the policy also allows all egress.")
}}
{{- range $removed }}
  {{- $path := splitList "." (index . 0) }}
  {{- $node := $.Values }}
  {{- $found := true }}
  {{- range $path }}
    {{- if and $found (kindIs "map" $node) (hasKey $node .) }}
      {{- $node = index $node . }}
    {{- else }}
      {{- $found = false }}
    {{- end }}
  {{- end }}
  {{- if $found }}
    {{- fail (printf "%s See UPGRADE.md." (index . 1)) }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Validate the persistence configuration.

The 0.x dataStorage and replica.persistence values are refused rather than
ignored: a standalone release that still sets dataStorage.enabled would
otherwise render without its PVC, so Helm would delete the claim and the pod
would start on an empty volume.
*/}}
{{- define "valkey.validatePersistence" -}}
{{- include "valkey.validateRemovedValues" . }}
{{- $p := .Values.persistence }}
{{- if and .Values.replica.enabled (lt (int .Values.replica.replicas) 1) }}
  {{- fail "replica.replicas counts the Valkey pods, the master included, and must be at least 1." }}
{{- end }}
{{- if .Values.replica.enabled }}
  {{- if not (and $p.enabled $p.size) }}
    {{- fail "Replication requires persistent storage, otherwise a restarted primary comes back empty and its replicas copy the empty dataset. Please set persistence.enabled=true and persistence.size (e.g. '5Gi')." }}
  {{- end }}
  {{- if or $p.existingClaim $p.hostPath $p.keepOnUninstall }}
    {{- fail "persistence.existingClaim, persistence.hostPath and persistence.keepOnUninstall only apply to standalone mode. In replication mode the StatefulSet creates one PVC per pod, named valkey-data-<statefulset>-<index>; pre-create claims with those names to reuse existing volumes." }}
  {{- end }}
{{- else if and $p.enabled (not (or $p.size $p.existingClaim $p.hostPath)) }}
  {{- fail "persistence.enabled needs persistence.size, persistence.existingClaim or persistence.hostPath." }}
{{- else if and (not $p.enabled) (or $p.size $p.existingClaim $p.hostPath) }}
  {{- /* 0.x mounted persistentVolumeClaimName and hostPath even with
         dataStorage.enabled false; silently switching those to an emptyDir
         would start Valkey on an empty data directory. */}}
  {{- fail "persistence.size, persistence.existingClaim or persistence.hostPath is set but persistence.enabled is false. Set persistence.enabled=true to use the volume, or remove them to run without persistence." }}
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
valkey-cli TLS flags shared by the Sentinel scripts and probes
*/}}
{{- define "valkey.sentinel.cliTlsFlags" -}}
{{- if .Values.tls.enabled -}}
--tls --cacert /tls/{{ .Values.tls.caPublicKey }}
{{- if .Values.tls.requireClientCertificate }} --cert /tls/{{ .Values.tls.serverPublicKey }} --key /tls/{{ .Values.tls.serverKey }}{{ end }}
{{- end -}}
{{- end -}}

{{/*
valkey-cli TLS flags for the commands printed after an install. Those run from
a shell rather than inside a chart pod, so the files are the operator's own
copies of what tls.existingSecret holds, and the names are shown as
placeholders instead of the paths mounted into the containers.
*/}}
{{- define "valkey.cli.tlsFlagsHint" -}}
{{- if .Values.tls.enabled }} --tls --cacert <{{ .Values.tls.caPublicKey }}>
{{- if .Values.tls.requireClientCertificate }} --cert <{{ .Values.tls.serverPublicKey }}> --key <{{ .Values.tls.serverKey }}>{{ end }}
{{- end }}
{{- end -}}

{{/*
TLS options for the Python example printed after an install. The Sentinel
connection and the connection to the master are separate, so the same options
have to be given twice: once inside sentinel_kwargs and once beside it.
*/}}
{{- define "valkey.python.tlsDictItems" -}}
{{- if .Values.tls.enabled }}, "ssl": True, "ssl_ca_certs": "<{{ .Values.tls.caPublicKey }}>"
{{- if .Values.tls.requireClientCertificate }}, "ssl_certfile": "<{{ .Values.tls.serverPublicKey }}>", "ssl_keyfile": "<{{ .Values.tls.serverKey }}>"{{ end }}
{{- end }}
{{- end -}}

{{- define "valkey.python.tlsKwargs" -}}
{{- if .Values.tls.enabled }},
           ssl=True, ssl_ca_certs="<{{ .Values.tls.caPublicKey }}>"
{{- if .Values.tls.requireClientCertificate }}, ssl_certfile="<{{ .Values.tls.serverPublicKey }}>", ssl_keyfile="<{{ .Values.tls.serverKey }}>"{{ end }}
{{- end }}
{{- end -}}

{{/*
Validate sentinel configuration
*/}}
{{- define "valkey.validateSentinelConfig" -}}
{{- if .Values.sentinel.enabled }}
  {{- if not .Values.replica.enabled }}
    {{- fail "Sentinel requires replication. Please set replica.enabled=true along with sentinel.enabled=true" }}
  {{- end }}
  {{- $sentinels := int .Values.sentinel.replicas }}
  {{- if lt (int .Values.replica.replicas) 2 }}
    {{- fail "Sentinel requires at least one Valkey replica to promote. Please set replica.replicas, which counts the master too, to 2 or more." }}
  {{- end }}
  {{- if lt $sentinels 3 }}
    {{- fail (printf "Sentinel requires at least 3 instances to form a quorum. Please set sentinel.replicas to 3 or more (currently %d)." $sentinels) }}
  {{- end }}
  {{- if lt (int .Values.sentinel.quorum) 2 }}
    {{- fail "sentinel.quorum must be at least 2, a quorum of 1 allows a single Sentinel to trigger a failover on its own." }}
  {{- end }}
  {{- if gt (int .Values.sentinel.quorum) $sentinels }}
    {{- fail (printf "sentinel.quorum (%d) cannot be greater than sentinel.replicas (%d)." (int .Values.sentinel.quorum) $sentinels) }}
  {{- end }}
  {{- if and .Values.sentinel.preStopFailover (ge (int .Values.sentinel.preStopFailoverTimeoutSeconds) (int .Values.terminationGracePeriodSeconds)) }}
    {{- fail (printf "sentinel.preStopFailoverTimeoutSeconds (%d) must be lower than terminationGracePeriodSeconds (%d), otherwise the pod is killed while the graceful failover is still running." (int .Values.sentinel.preStopFailoverTimeoutSeconds) (int .Values.terminationGracePeriodSeconds)) }}
  {{- end }}
  {{- if .Values.sentinel.podDisruptionBudget.enabled }}
    {{- if and (kindIs "invalid" .Values.sentinel.podDisruptionBudget.minAvailable) (kindIs "invalid" .Values.sentinel.podDisruptionBudget.maxUnavailable) }}
      {{- fail "sentinel.podDisruptionBudget needs either minAvailable or maxUnavailable. A budget with neither is accepted by the API server but protects nothing." }}
    {{- end }}
    {{- /* A failover needs quorum Sentinels to agree the master is down and a
           majority of all Sentinels to elect the leader that performs it, so
           the budget must keep max(quorum, majority) Sentinels running.
           Kubernetes rounds percentages up for both fields. */}}
    {{- $pdb := .Values.sentinel.podDisruptionBudget }}
    {{- $needed := max (int .Values.sentinel.quorum) (add (div $sentinels 2) 1) }}
    {{- $field := ternary "maxUnavailable" "minAvailable" (kindIs "invalid" $pdb.minAvailable) }}
    {{- $value := ternary $pdb.maxUnavailable $pdb.minAvailable (kindIs "invalid" $pdb.minAvailable) }}
    {{- $count := 0 }}
    {{- if hasSuffix "%" (toString $value) }}
      {{- $count = div (add (mul $sentinels (int (trimSuffix "%" (toString $value)))) 99) 100 }}
    {{- else }}
      {{- $count = int $value }}
    {{- end }}
    {{- $kept := ternary (sub $sentinels $count) $count (eq $field "maxUnavailable") }}
    {{- if lt (int $kept) (int $needed) }}
      {{- fail (printf "sentinel.podDisruptionBudget.%s (%v) lets voluntary evictions leave %d of %d Sentinels running, but a failover needs %d: sentinel.quorum (%d) to agree and a majority of all Sentinels to elect a leader. Add Sentinels, lower the quorum, or tighten the budget." $field $value (int $kept) $sentinels (int $needed) (int .Values.sentinel.quorum)) }}
    {{- end }}
  {{- end }}
  {{- $bootstrapWait := int .Values.sentinel.initialTopologyWaitSeconds }}
  {{- $sentinelStartup := int .Values.sentinel.startupTimeoutSeconds }}
  {{- if lt $bootstrapWait (add $sentinelStartup 30) }}
    {{- fail (printf "sentinel.initialTopologyWaitSeconds (%d) must be at least 30s above sentinel.startupTimeoutSeconds (%d), which is %d. A pod with no recorded topology has nothing to be told until the Sentinels finish that discovery and bootstrap a master, so a shorter wait leaves the init container exiting just before the answer arrives." $bootstrapWait $sentinelStartup (add $sentinelStartup 30)) }}
  {{- end }}
  {{- if and .Values.sentinel.password .Values.sentinel.existingSecret }}
    {{- fail "Set either sentinel.password or sentinel.existingSecret, not both." }}
  {{- end }}
  {{- if not (or .Values.sentinel.password .Values.sentinel.existingSecret) }}
    {{- fail "Sentinel requires its own password: set sentinel.password, or sentinel.existingSecret with the password under sentinel.passwordKey." }}
  {{- end }}
  {{- if .Values.auth.enabled }}
    {{- $monitorUser := .Values.sentinel.monitorUser | default .Values.replica.replicationUser }}
    {{- if not (hasKey .Values.auth.aclUsers $monitorUser) }}
      {{- fail (printf "Sentinel monitor user '%s' must be defined in auth.aclUsers. Sentinel needs it to reach the monitored Valkey nodes." $monitorUser) }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Selector labels for the HAProxy pods.

The name deliberately differs from the Valkey one. Every Valkey side selector,
the PodDisruptionBudget and the headless service among them, matches on
app.kubernetes.io/name plus instance without a component, so sharing the Valkey
name would make those select the proxy pods as well.
*/}}
{{- define "valkey.haproxy.selectorLabels" -}}
app.kubernetes.io/name: {{ printf "%s-haproxy" (include "valkey.name" . | trunc 55 | trimSuffix "-") }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: haproxy
{{- end -}}

{{/*
Common labels for the HAProxy resources
*/}}
{{- define "valkey.haproxy.labels" -}}
helm.sh/chart: {{ include "valkey.chart" . }}
{{ include "valkey.haproxy.selectorLabels" . }}
{{- include "valkey.versionLabel" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end -}}

{{/*
Returns the HAProxy container image
*/}}
{{- define "valkey.haproxy.image" -}}
{{- include "valkey.common.image" (dict "image" .Values.haproxy.image "global" .Values.global) }}
{{- end -}}

{{/*
Per-server TLS options for the HAProxy backends.
Only the health check speaks TLS (check-ssl). The client stream is forwarded
untouched, so the client completes the handshake with the node itself and
HAProxy never holds a client's identity.
*/}}
{{- define "valkey.haproxy.serverTlsOptions" -}}
{{- if .Values.tls.enabled }} check-ssl
{{- if eq .Values.haproxy.tls.verify "required" }} ca-file /tls/{{ .Values.tls.caPublicKey }} verify required
{{- else }} verify none
{{- end }}
{{- if .Values.tls.requireClientCertificate }} crt /tls/{{ .Values.haproxy.tls.clientCertFile }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
TLS options for HAProxy's checks of the Sentinels. The check connects with
"tcp-check connect ssl", so check-ssl is not needed here.
*/}}
{{- define "valkey.haproxy.sentinelTlsOptions" -}}
{{- if .Values.tls.enabled }}
{{- if eq .Values.haproxy.tls.verify "required" }} ca-file /tls/{{ .Values.tls.caPublicKey }} verify required
{{- else }} verify none
{{- end }}
{{- if .Values.tls.requireClientCertificate }} crt /tls/{{ .Values.haproxy.tls.clientCertFile }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Per-server certificate identity options for an HAProxy backend.
*/}}
{{/*
Source of the TLS volume, mounted at /tls by every pod that reads TLS files:
tls.volume as given, or tls.existingSecret as a secret volume. Exactly one of
the two must be set when TLS is enabled.
*/}}
{{- define "valkey.tls.volumeSource" -}}
{{- $tls := .Values.tls }}
{{- if and $tls.existingSecret $tls.volume }}
  {{- fail "tls.existingSecret and tls.volume are both set. Use tls.existingSecret for a Secret, or tls.volume for any other volume source." }}
{{- end }}
{{- if $tls.volume }}
{{- toYaml $tls.volume }}
{{- else }}
secret:
  secretName: {{ required "TLS needs tls.existingSecret or tls.volume." $tls.existingSecret }}
  defaultMode: 0400
{{- end }}
{{- end -}}

{{/*
Mount paths the chart uses itself. A mount from extraVolumeMounts on one of
them, or below one, would hide or be hidden by the chart's own.
*/}}
{{- define "valkey.validateMountPaths" -}}
{{- $checks := list
  (list "extraVolumeMounts" .Values.extraVolumeMounts (list "/data" "/valkey-conf" "/scripts" "/sentinel-scripts" "/sentinel-auth" "/tls" "/valkey-users-secret" "/valkey-auth-secret"))
  (list "metrics.exporter.extraVolumeMounts" .Values.metrics.exporter.extraVolumeMounts (list "/tls"))
  (list "haproxy.extraVolumeMounts" .Values.haproxy.extraVolumeMounts (list "/tls" "/usr/local/etc/haproxy"))
}}
{{- range $checks }}
  {{- $value := index . 0 }}
  {{- $reserved := index . 2 }}
  {{- range (index . 1) }}
    {{- $path := .mountPath | toString | trimSuffix "/" }}
    {{- range $reserved }}
      {{- if or (eq $path .) (hasPrefix (printf "%s/" .) $path) }}
        {{- if eq . "/tls" }}
          {{- fail (printf "%s mounts %s, which the chart uses for the TLS files. The chart mounts tls.existingSecret or tls.volume there itself; put any other TLS files into tls.volume. See UPGRADE.md." $value $path) }}
        {{- end }}
        {{- fail (printf "%s mounts %s, which the chart uses itself (%s). Mount it somewhere else." $value $path (join ", " $reserved)) }}
      {{- end }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Keys of tls.existingSecret that HAProxy reads, as a JSON list. Only these are
mounted, so the Valkey server's private key never reaches the HAProxy pods.
With a tls.volume, which cannot be narrowed down like this, they are mounted
one by one with subPath instead. Must stay in line with the files
valkey.haproxy.serverTlsOptions references.
*/}}
{{- define "valkey.haproxy.tlsFiles" -}}
{{- $files := list -}}
{{- if .Values.tls.enabled -}}
{{- if eq .Values.haproxy.tls.verify "required" -}}
{{- $files = append $files .Values.tls.caPublicKey -}}
{{- end -}}
{{- if .Values.tls.requireClientCertificate -}}
{{- $files = append $files .Values.haproxy.tls.clientCertFile -}}
{{- end -}}
{{- end -}}
{{- toJson $files -}}
{{- end -}}

{{- define "valkey.haproxy.serverTlsIdentityOptions" -}}
{{- $root := .root -}}
{{- if and $root.Values.tls.enabled (eq $root.Values.haproxy.tls.verify "required") -}}
{{- $host := printf "%s-%d.%s.%s.svc.%s" (include "valkey.statefulsetName" $root) .index (include "valkey.headlessServiceName" $root) $root.Release.Namespace $root.Values.clusterDomain -}}
{{- printf " verifyhost %s" $host -}}
{{- end -}}
{{- end -}}

{{/*
Validate haproxy configuration
*/}}
{{- define "valkey.validateHaproxyConfig" -}}
{{- if .Values.haproxy.enabled }}
  {{- if not (and .Values.replica.enabled .Values.sentinel.enabled) }}
    {{- fail "HAProxy routes clients to whichever node Sentinel promoted. Please set replica.enabled=true and sentinel.enabled=true, or disable haproxy." }}
  {{- end }}
  {{- if .Values.haproxy.podDisruptionBudget.enabled }}
    {{- if and (kindIs "invalid" .Values.haproxy.podDisruptionBudget.minAvailable) (kindIs "invalid" .Values.haproxy.podDisruptionBudget.maxUnavailable) }}
      {{- fail "haproxy.podDisruptionBudget needs either minAvailable or maxUnavailable. A budget with neither is accepted by the API server but protects nothing." }}
    {{- end }}
  {{- end }}
  {{- if regexMatch "^0+(us|ms|s|m|h|d)?$" (toString .Values.haproxy.config.timeout.tunnel) }}
    {{- fail "haproxy.config.timeout.tunnel must be greater than 0. HAProxy treats 0 as unset rather than unlimited, so idle pub/sub connections would be dropped after timeout.client. Use a large value such as 24d instead." }}
  {{- end }}
  {{- if and .Values.tls.enabled .Values.tls.requireClientCertificate (not .Values.haproxy.tls.clientCertFile) }}
    {{- fail "tls.requireClientCertificate needs haproxy.tls.clientCertFile. HAProxy loads a client certificate from a single file holding both the certificate and its private key, which tls.serverPublicKey and tls.serverKey do not provide separately." }}
  {{- end }}
  {{- if .Values.auth.enabled }}
    {{- $checkUser := .Values.haproxy.checkUser | default "default" }}
    {{- if not (hasKey .Values.auth.aclUsers $checkUser) }}
      {{- fail (printf "HAProxy check user '%s' must be defined in auth.aclUsers. HAProxy needs it to run the health check that finds the master." $checkUser) }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Render the Valkey server container health probes (startupProbe, livenessProbe,
readinessProbe). Each probe is gated on its own `enabled` flag. When a probe's
`customProbe` map is set it replaces the default handler and timing entirely;
otherwise the default valkey-cli ping exec handler (TLS-aware) is emitted with
whichever timing fields are set on that probe. The command is built as an
argument list and invokes valkey-cli directly (no shell), with the TLS flags
appended only when `tls.enabled` is set. Returns nothing when no probe is
enabled, so callers should guard with `with`.
*/}}
{{- define "valkey.healthProbes" -}}
{{- $cmd := list "valkey-cli" -}}
{{- if $.Values.tls.enabled -}}
{{- $cmd = concat $cmd (list "--cacert" (printf "/tls/%s" $.Values.tls.caPublicKey) "--cert" (printf "/tls/%s" $.Values.tls.serverPublicKey) "--key" (printf "/tls/%s" $.Values.tls.serverKey) "--tls") -}}
{{- end -}}
{{- $cmd = append $cmd "ping" -}}
{{- $probes := dict -}}
{{- range $name := (list "startupProbe" "livenessProbe" "readinessProbe") -}}
{{- $probe := index $.Values $name -}}
{{- if $probe -}}
{{- if $probe.enabled -}}
{{- if $probe.customProbe -}}
{{- $probes = set $probes $name $probe.customProbe -}}
{{- else -}}
{{- $rendered := dict "exec" (dict "command" $cmd) -}}
{{- range $field := (list "initialDelaySeconds" "periodSeconds" "timeoutSeconds" "failureThreshold" "successThreshold") -}}
{{- if hasKey $probe $field -}}{{- $rendered = set $rendered $field (index $probe $field) -}}{{- end -}}
{{- end -}}
{{- $probes = set $probes $name $rendered -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $probes -}}
{{- toYaml $probes -}}
{{- end -}}
{{- end -}}

{{/*
Checksum of the chart-managed auth Secret's data, so that pods restart when an
inline password changes. Only the data is hashed, not the labels, so a chart
version bump alone does not change it. Empty when the chart renders no Secret.
*/}}
{{- define "valkey.authSecretChecksum" -}}
{{- $secret := include (print .Template.BasePath "/secret.yaml") . | fromYaml }}
{{- with $secret.data }}
{{- toJson . | sha256sum | trunc 32 }}
{{- end }}
{{- end -}}
