{{/*
Expand the name of the chart.
*/}}
{{- define "valkey-operator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "valkey-operator.fullname" -}}
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
{{- define "valkey-operator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "valkey-operator.labels" -}}
helm.sh/chart: {{ include "valkey-operator.chart" . }}
{{ include "valkey-operator.selectorLabels" . }}
{{- if or .Values.image.tag .Chart.AppVersion }}
app.kubernetes.io/version: {{ mustRegexReplaceAllLiteral "@sha.*" .Values.image.tag "" | default .Chart.AppVersion | trunc 63 | trimSuffix "-" | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "valkey-operator.selectorLabels" -}}
app.kubernetes.io/name: {{ include "valkey-operator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "valkey-operator.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "valkey-operator.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Rules for the operator manager, shared by the cluster-wide ClusterRole and the
per-namespace Roles. Keep in sync with config/rbac/role.yaml in the operator
release this chart bundles.
*/}}
{{- define "valkey-operator.managerRules" -}}
- apiGroups:
  - ""
  resources:
  - configmaps
  - persistentvolumeclaims
  - secrets
  - services
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - ""
  resources:
  - pods
  verbs:
  - delete
  - get
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - serviceaccounts
  verbs:
  - get
- apiGroups:
  - apps
  resources:
  - deployments
  - statefulsets
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - events.k8s.io
  resources:
  - events
  verbs:
  - create
  - patch
- apiGroups:
  - policy
  resources:
  - poddisruptionbudgets
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - valkey.io
  resources:
  - valkeyclusters
  - valkeynodes
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - valkey.io
  resources:
  - valkeyclusters/finalizers
  - valkeynodes/finalizers
  verbs:
  - update
- apiGroups:
  - valkey.io
  resources:
  - valkeyclusters/status
  - valkeynodes/status
  verbs:
  - get
  - patch
  - update
{{- end }}

{{/*
Returns the operator container image
*/}}
{{- define "valkey-operator.image" -}}
{{- include "common.image" (dict "image" (dict "registry" .Values.image.registry "repository" .Values.image.repository "tag" (.Values.image.tag | default .Chart.AppVersion)) "global" .Values.global) }}
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
{{- end }}
{{- end -}}

{{/*
Returns the image pull secrets
*/}}
{{- define "valkey-operator.imagePullSecrets" -}}
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
{{- end }}
