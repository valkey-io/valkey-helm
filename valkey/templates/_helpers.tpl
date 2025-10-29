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
Creating Image Pull Secrets
*/}}
{{- define "imagePullSecret" }}
{{- with .Values.imageCredentials }}
{{- printf "{\"auths\":{\"%s\":{\"username\":\"%s\",\"password\":\"%s\",\"email\":\"%s\",\"auth\":\"%s\"}}}" .registry .username .password .email (printf "%s:%s" .username .password | b64enc) | b64enc }}
{{- end }}
{{- end }}

{{- define "valkey.secretName" -}}
{{- if .Values.imagePullSecrets.nameOverride }}
{{- .Values.imagePullSecrets.nameOverride }}
{{- else }}
{{- printf "%s-regcred" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Validate auth configuration
*/}}
{{- define "valkey.validateAuthConfig" -}}
{{- if .Values.auth.enabled }}
  {{- $methodCount := 0 }}
  {{- if .Values.auth.generateDefaultUser.enabled }}
    {{- $methodCount = add $methodCount 1 }}
  {{- end }}
  {{- if .Values.auth.existingSecret }}
    {{- $methodCount = add $methodCount 1 }}
  {{- end }}
  {{- /* Check if aclConfig has actual content (not just comments/whitespace) */}}
  {{- if .Values.auth.aclConfig }}
    {{- $trimmed := .Values.auth.aclConfig | trim }}
    {{- /* Use regex to check for any non-empty, non-comment line */}}
    {{- $hasContent := regexMatch "(?m)^(\s*[^#\s].*)$" $trimmed }}
    {{- if $hasContent }}
      {{- $methodCount = add $methodCount 1 }}
    {{- end }}
  {{- end }}
  {{- if eq $methodCount 0 }}
    {{- fail "auth.enabled is true but no authentication method is configured. Please enable one of: auth.generateDefaultUser.enabled, auth.existingSecret, or provide auth.aclConfig" }}
  {{- end }}
  {{- if gt $methodCount 1 }}
    {{- fail "Multiple authentication methods are enabled. Please enable only ONE of: auth.generateDefaultUser.enabled, auth.existingSecret, or auth.aclConfig" }}
  {{- end }}
{{- end }}
{{- end }}

