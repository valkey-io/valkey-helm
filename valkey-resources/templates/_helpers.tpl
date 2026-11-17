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

{{/*
Deep-merge dict "src" into dict "dst", in place, and output nothing.
A null in src deletes the key from dst. A map in src recurses, into an empty
map when dst has no map there, so its nested nulls are dropped too. Anything
else replaces, including false, 0, "" and lists, which mergeOverwrite would skip.
*/}}
{{- define "valkey-resources.deepMerge" -}}
{{- $dst := .dst }}
{{- range $key, $value := .src }}
{{- if kindIs "invalid" $value }}
{{- $_ := unset $dst $key }}
{{- else if kindIs "map" $value }}
{{- if not (kindIs "map" (get $dst $key)) }}
{{- $_ := set $dst $key dict }}
{{- end }}
{{- include "valkey-resources.deepMerge" (dict "dst" (get $dst $key) "src" $value) }}
{{- else }}
{{- $_ := set $dst $key (deepCopy $value) }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Convert the value at "path" under dict "parent" from a map to a list, in
place, and output nothing. A missing key, a list, or a path through something
that is not a map stays as it is. The list is sorted by map key.
A null entry is skipped, an empty one is kept. With "named", a map entry is
copied and gets name: <key> unless it has a non-empty name. A non-map entry is
used as it is, unless "scalarKey" is set: then it becomes
{name: <key>, <scalarKey>: <value as string>}. Helm reads numbers in values
files as float64, so a whole number is converted to int64 first: 1000000
renders as "1000000", not "1e+06".
Call with (dict "parent" <map> "path" (list "acl" "users") "named" true), or
add "scalarKey" "value" for env.
*/}}
{{- define "valkey-resources.listOrMap" -}}
{{- $parent := .parent }}
{{- range $step := initial .path }}
{{- $next := get $parent $step }}
{{- $parent = ternary $next dict (kindIs "map" $next) }}
{{- end }}
{{- $key := last .path }}
{{- $value := get $parent $key }}
{{- if kindIs "map" $value }}
{{- $list := list }}
{{- range $name := keys $value | sortAlpha }}
{{- $entry := get $value $name }}
{{- if not (kindIs "invalid" $entry) }}
{{- if and $.named (kindIs "map" $entry) }}
{{- $entry = deepCopy $entry }}
{{- if not $entry.name }}
{{- $_ := set $entry "name" $name }}
{{- end }}
{{- else if and $.named $.scalarKey (not (kindIs "map" $entry)) }}
{{- if and (kindIs "float64" $entry) (eq $entry (float64 (int64 $entry))) }}
{{- $entry = int64 $entry }}
{{- end }}
{{- $entry = dict "name" $name $.scalarKey (toString $entry) }}
{{- end }}
{{- $list = append $list $entry }}
{{- end }}
{{- end }}
{{- $_ := set $parent $key $list }}
{{- end }}
{{- end }}

{{/*
Image reference [registry/]repository[:tag][@sha256:sha].
global.imageRegistry overrides the per-image registry.
Call with (dict "image" <map> "global" <map or nil> "path" "cluster.image").
*/}}
{{- define "valkey-resources.image" -}}
{{- $image := .image | default dict }}
{{- $global := .global | default dict }}
{{- $registry := $global.imageRegistry | default $image.registry | default "" }}
{{- $tag := $image.tag | default "" | toString }}
{{- $sha := $image.sha | default "" | toString | trimPrefix "sha256:" }}
{{- if not $image.repository }}
{{- fail (printf "%s: set repository" .path) }}
{{- end }}
{{- if and (not $tag) (not $sha) }}
{{- fail (printf "%s: set tag or sha" .path) }}
{{- end }}
{{- with $registry }}{{ . }}/{{ end }}
{{- $image.repository }}
{{- with $tag }}:{{ . }}{{ end }}
{{- with $sha }}@sha256:{{ . }}{{ end }}
{{- end }}
