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
