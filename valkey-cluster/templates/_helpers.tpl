{{/*
Return the appropriate apiVersion for poddisruptionbudget.
*/}}
{{- define "valkey-cluster.capabilities.policy.apiVersion" -}}
{{- print "policy/v1" -}}
{{- end -}}

{{/*
Returns a custom namespace from `.Values.namespace` if set, otherwise defaults to
the release namespace (`.Release.Namespace`).
*/}}
{{- define "valkey-cluster.names.namespace" -}}
{{- default .Release.Namespace .Values.namespace | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* vim: set filetype=mustache: */}}

{{/*
This allows a value from `values.yaml` to be either static (e.g., `port: 80`)
or dynamic (e.g., `port: "{{ .Values.global.port }}"`).
*/}}
{{- define "valkey-cluster.tplvalues.render" -}}
{{- $value := typeIs "string" .value | ternary .value (.value | toYaml) }}
{{- if contains "{{" (toJson .value) }}
  {{- if .scope }}
      {{- tpl (cat "{{- with $.RelativeScope -}}" $value "{{- end }}") (merge (dict "RelativeScope" .scope) .context) }}
  {{- else }}
    {{- tpl $value .context }}
  {{- end }}
{{- else }}
    {{- $value }}
{{- end }}
{{- end -}}

{{/*
Renders and merges a list of dictionaries into a single YAML output.

It processes any Helm template syntax within each dictionary before combining them.
The merge order gives precedence to the last item in the list ("last one wins"),
making it ideal for layering configurations like defaults and overrides.

Usage:
{{ include "valkey-cluster.tplvalues.merge" (dict "values" (list .Values.defaults .Values.overrides) "context" $) }}
*/}}
{{- define "valkey-cluster.tplvalues.merge" -}}
{{- $dst := dict -}}
{{- range .values -}}
{{- $dst = include "valkey-cluster.tplvalues.render" (dict "value" . "context" $.context "scope" $.scope) | fromYaml | merge $dst -}}
{{- end -}}
{{ $dst | toYaml }}
{{- end -}}

{{/*
Generates the full image name for the metrics exporter.

It combines the values from `.Values.metrics.image` with global settings
(like `.Values.global.imageRegistry`) to create a complete, pullable image name.
*/}}
{{- define "valkey-cluster.metrics.image" -}}
{{ include "valkey-cluster.images.image" (dict "imageRoot" .Values.metrics.image "global" .Values.global) }}
{{- end -}}

{{/*
Generates a complete and pullable container image name.

This helper function constructs the full image identifier by combining a registry, repository, and a tag or digest. It uses a specific order of precedence to determine the final name:

1.  **Registry:** Uses the `image.registry` value if provided; otherwise, it falls back to `global.imageRegistry`.
2.  **Repository:** Uses the `image.repository` value.
3.  **Termination (Tag/Digest Priority):**
    - If `image.digest` is set, it's used with an '@' separator (e.g., `... @sha256:...`).
    - If `image.digest` is not set but `image.tag` is, the tag is used with a ':' separator (e.g., `... :1.2.3`).
    - If neither is set, it falls back to using the chart's `.Chart.AppVersion` as the tag.

Example Usage:
{{ include "valkey-cluster.images.image" ( dict "imageRoot" .Values.myApp.image "global" .Values.global "chart" .Chart ) }}
*/}}
{{- define "valkey-cluster.images.image" -}}
{{- $registryName := default .imageRoot.registry .global.imageRegistry -}}
{{- $repositoryName := .imageRoot.repository -}}
{{- $separator := ":" -}}
{{- $termination := .imageRoot.tag | toString -}}

{{- if not .imageRoot.tag }}
    {{- if .chart }}
        {{- $termination = .chart.AppVersion | toString -}}
    {{- end }}
{{- end -}}
{{- if .imageRoot.digest }}
    {{- $separator = "@" -}}
    {{- $termination = .imageRoot.digest | toString -}}
{{- end -}}
{{- if $registryName }}
    {{- printf "%s/%s%s%s" $registryName $repositoryName $separator $termination -}}
{{- else -}}
    {{- printf "%s%s%s" $repositoryName $separator $termination -}}
{{- end -}}
{{- end -}}

{{/*
Generate Valkey configuration.
- Renders the base config from .Values.valkeyConfig.
- If auth is enabled, it appends the 'requirepass' and 'masterauth' lines.
- If replicaCount > 1, it appends cluster settings using ports from .Values.containerPorts.
*/}}
{{- define "valkey-cluster.generateConfig" -}}
{{- $useAuth := false -}}
{{- if and .Values.existingSecret .Values.existingSecretPasswordKey -}}
  {{- if and (ne .Values.existingSecret "") (ne .Values.existingSecretPasswordKey "") -}}
    {{- $useAuth = true -}}
  {{- end -}}
{{- end -}}
{{- .Values.valkeyConfig | nindent 0 }}
{{- if $useAuth }}
requirepass {dynamically-substituted-dont-change-manually}
protected-mode yes
{{- end }}
{{- if gt (int .Values.replicaCount) 1 }}
cluster-enabled yes
cluster-config-file nodes.conf
cluster-node-timeout 5000
cluster-allow-reads-when-down yes
cluster-announce-port {{ .Values.containerPorts.valkey }}
cluster-announce-bus-port {{ .Values.containerPorts.bus }}
cluster-port {{ .Values.containerPorts.bus }}
{{- end }}
{{- end -}}

{{/*
Expand the name of the chart.
*/}}
{{- define "valkey-cluster.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "valkey-cluster.fullname" -}}
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
{{- define "valkey-cluster.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "valkey-cluster.labels" -}}
helm.sh/chart: {{ include "valkey-cluster.chart" . }}
{{ include "valkey-cluster.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "valkey-cluster.selectorLabels" -}}
app.kubernetes.io/name: {{ include "valkey-cluster.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Standard labels for all resources.
Merges in custom labels provided via the 'customLabels' dictionary.
*/}}
{{- define "valkey-cluster.standardlabels" -}}
{{- $standardLabels := include "valkey-cluster.labels" .context | fromYaml }}
{{- $customLabels := .customLabels | fromYaml }}
{{- $merged := merge $customLabels $standardLabels }}
{{- toYaml $merged }}
{{- end -}}

{{/*
Generates selector labels for services and other resources.
Merges custom labels with the chart's standard selector labels.
*/}}
{{- define "valkey-cluster.matchLabels" -}}
{{- $selectorLabels := include "valkey-cluster.selectorLabels" .context | fromYaml }}
{{- $customLabels := .customLabels | fromYaml }}
{{- $merged := merge $customLabels $selectorLabels }}
{{- toYaml $merged }}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "valkey-cluster.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "valkey-cluster.fullname" .) .Values.serviceAccount.name }}
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

{{- define "valkey-cluster.secretName" -}}
{{- if .Values.imagePullSecrets.nameOverride }}
{{- .Values.imagePullSecrets.nameOverride }}
{{- else }}
{{- printf "%s-regcred" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

