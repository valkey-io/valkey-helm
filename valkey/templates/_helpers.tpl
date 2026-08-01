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
valkey-cli TLS flags shared by the Sentinel scripts and probes
*/}}
{{- define "valkey.sentinel.cliTlsFlags" -}}
{{- if .Values.tls.enabled -}}
--tls --cacert /tls/{{ .Values.tls.caPublicKey }}
{{- if .Values.tls.requireClientCertificate }} --cert /tls/{{ .Values.tls.serverPublicKey }} --key /tls/{{ .Values.tls.serverKey }}{{ end }}
{{- end -}}
{{- end -}}

{{/*
Validate sentinel configuration
*/}}
{{- define "valkey.validateSentinelConfig" -}}
{{- if .Values.replica.sentinel.enabled }}
  {{- if not .Values.replica.enabled }}
    {{- fail "Sentinel requires replication. Please set replica.enabled=true along with replica.sentinel.enabled=true" }}
  {{- end }}
  {{- $pods := add (int .Values.replica.replicas) 1 }}
  {{- if lt $pods 3 }}
    {{- fail (printf "Sentinel requires at least 3 pods to form a quorum, replica.replicas=%d gives %d. Please set replica.replicas to 2 or more." (int .Values.replica.replicas) $pods) }}
  {{- end }}
  {{- if lt (int .Values.replica.sentinel.quorum) 2 }}
    {{- fail "replica.sentinel.quorum must be at least 2, a quorum of 1 allows a single Sentinel to trigger a failover on its own." }}
  {{- end }}
  {{- if gt (int .Values.replica.sentinel.quorum) $pods }}
    {{- fail (printf "replica.sentinel.quorum (%d) cannot be greater than the number of Sentinels (%d)." (int .Values.replica.sentinel.quorum) $pods) }}
  {{- end }}
  {{- if .Values.auth.enabled }}
    {{- $monitorUser := .Values.replica.sentinel.monitorUser | default .Values.replica.replicationUser }}
    {{- if not (hasKey .Values.auth.aclUsers $monitorUser) }}
      {{- fail (printf "Sentinel monitor user '%s' must be defined in auth.aclUsers. Sentinel needs it to reach the monitored Valkey nodes." $monitorUser) }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Returns the HAProxy container image
*/}}
{{- define "valkey.haproxy.image" -}}
{{- include "common.image" (dict "image" .Values.haproxy.image "global" .Values.global) }}
{{- end -}}

{{/*
Per-server TLS options for the HAProxy backends
*/}}
{{- define "valkey.haproxy.serverTlsOptions" -}}
{{- if .Values.tls.enabled }} ssl
{{- if eq .Values.haproxy.tls.verify "required" }} ca-file /tls/{{ .Values.tls.caPublicKey }} verify required
{{- else }} verify none
{{- end }}
{{- if .Values.tls.requireClientCertificate }} crt /tls/{{ .Values.tls.serverPublicKey }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Validate haproxy configuration
*/}}
{{- define "valkey.validateHaproxyConfig" -}}
{{- if .Values.haproxy.enabled }}
  {{- if not (and .Values.replica.enabled .Values.replica.sentinel.enabled) }}
    {{- fail "HAProxy routes clients to whichever node Sentinel promoted. Please set replica.enabled=true and replica.sentinel.enabled=true, or disable haproxy." }}
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
{{- $cmd = concat $cmd (list "--cacert" (printf "/tls/%s" $.Values.tls.caPublicKey) "--tls") -}}
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

