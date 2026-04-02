{{- define "valkey.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

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

{{- define "valkey.namespace" -}}
{{- if .Values.namespaceOverride }}
{{- .Values.namespaceOverride }}
{{- else }}
{{- .Release.Namespace }}
{{- end }}
{{- end }}

{{- define "valkey.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "valkey.labels" -}}
helm.sh/chart: {{ include "valkey.chart" . }}
{{ include "valkey.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "valkey.selectorLabels" -}}
app.kubernetes.io/name: {{ include "valkey.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "valkey.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "valkey.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "valkey.password" -}}
{{- if .Values.auth.existingSecret }}
{{- printf "%s" .Values.auth.existingSecret }}
{{- else if .Values.auth.password }}
{{- .Values.auth.password }}
{{- else }}
{{- randAlphaNum 32 }}
{{- end }}
{{- end }}

{{- define "valkey.secretPasswordKey" -}}
{{- if .Values.auth.existingSecretPasswordKey }}
{{- .Values.auth.existingSecretPasswordKey }}
{{- else }}
{{- "password" }}
{{- end }}
{{- end }}