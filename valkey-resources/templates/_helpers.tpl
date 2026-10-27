{{/*
Expand the name of the chart.
*/}}
{{- define "valkey-resources.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
The ValkeyCluster name, also used for the other objects the chart renders:
fullnameOverride if set, else the release name. The operator already prefixes
the objects it creates with "valkey-", so no chart-name suffix is added.
As an aliased subchart, .Chart.Name is the alias. Aliased copies keep the
0.4.x name so an upgrade does not rename them: the release name if it already
contains the alias (or nameOverride), else <release>-<alias>.
The CRD validates the length, which depends on shards, replicas and workloadType.
*/}}
{{- define "valkey-resources.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else if ne .Chart.Name "valkey-resources" }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "valkey-resources.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "valkey-resources.labels" -}}
helm.sh/chart: {{ include "valkey-resources.chart" . }}
{{ include "valkey-resources.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "valkey-resources.selectorLabels" -}}
app.kubernetes.io/name: {{ include "valkey-resources.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name: serviceAccount.name if set, else the fullname.
*/}}
{{- define "valkey-resources.serviceAccountName" -}}
{{- tpl (default (include "valkey-resources.fullname" .) .Values.serviceAccount.name) . }}
{{- end }}
{{/*
Users Secret name. Defaults to <fullname>-users, the Secret the operator reads
ACL user passwords from unless spec.users[].passwordSecret.name is set.
*/}}
{{- define "valkey-resources.usersSecretName" -}}
{{- tpl (default (printf "%s-users" (include "valkey-resources.fullname" .)) .Values.usersSecret.name) . }}
{{- end }}
