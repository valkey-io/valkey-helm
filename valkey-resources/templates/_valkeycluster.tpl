{{/*
Steps that build the ValkeyCluster spec. templates/valkeycluster.yaml calls
them in order on a deep copy of cluster.spec. Each step changes dict "spec" in
place and outputs nothing. Call with (dict "spec" $spec "root" $).
*/}}

{{/*
Merge cluster.additionalSpec, then cluster.additionalSpecString rendered
through tpl and parsed as YAML, over the spec.
*/}}
{{- define "valkey-resources.spec.additional" -}}
{{- $spec := .spec }}
{{- $root := .root }}
{{- include "valkey-resources.deepMerge" (dict "dst" $spec "src" (deepCopy ($root.Values.cluster.additionalSpec | default dict))) }}
{{- with $root.Values.cluster.additionalSpecString }}
{{- $extra := fromYaml (tpl . $root) }}
{{- if hasKey $extra "Error" }}
{{- fail (printf "cluster.additionalSpecString is not valid YAML: %s" $extra.Error) }}
{{- end }}
{{- include "valkey-resources.deepMerge" (dict "dst" $spec "src" $extra) }}
{{- end }}
{{- end }}

{{/*
Fields that take a list also take a map. Convert the maps to the CRD's list
form. Runs after the merge, so maps from cluster.spec and additionalSpec
combine entry by entry.
*/}}
{{- define "valkey-resources.spec.mapsToLists" -}}
{{- $spec := .spec }}
{{- include "valkey-resources.listOrMap" (dict "parent" $spec "path" (list "containers") "named" true) }}
{{- range $container := ($spec.containers | default list) }}
{{- if kindIs "map" $container }}
{{- include "valkey-resources.listOrMap" (dict "parent" $container "path" (list "env") "named" true "scalarKey" "value") }}
{{- end }}
{{- end }}
{{- include "valkey-resources.listOrMap" (dict "parent" $spec "path" (list "imagePullSecrets") "named" true) }}
{{- include "valkey-resources.listOrMap" (dict "parent" $spec "path" (list "acl" "users") "named" true) }}
{{- include "valkey-resources.listOrMap" (dict "parent" $spec "path" (list "scheduling" "tolerations")) }}
{{- include "valkey-resources.listOrMap" (dict "parent" $spec "path" (list "scheduling" "topologySpreadConstraints")) }}
{{- include "valkey-resources.listOrMap" (dict "parent" $spec "path" (list "networking" "tls" "clientAuth" "ca")) }}
{{- end }}

{{/*
Pin the Valkey and exporter images so an operator upgrade does not change
them. A non-empty image already in the spec, from cluster.spec or
additionalSpec, wins.
*/}}
{{- define "valkey-resources.spec.images" -}}
{{- $spec := .spec }}
{{- $values := .root.Values }}
{{- $image := $values.cluster.image }}
{{- if and (kindIs "map" $image) $image (not $spec.image) }}
{{- $_ := set $spec "image" (include "valkey-resources.image" (dict "image" $image "global" $values.global "path" "cluster.image")) }}
{{- end }}
{{- $exporterImage := ($values.cluster.exporter | default dict).image }}
{{- if and (kindIs "map" $exporterImage) $exporterImage }}
{{- $exporter := $spec.exporter }}
{{- if not (kindIs "map" $exporter) }}
{{- $exporter = dict }}
{{- end }}
{{- if not $exporter.image }}
{{- $_ := set $exporter "image" (include "valkey-resources.image" (dict "image" $exporterImage "global" $values.global "path" "cluster.exporter.image")) }}
{{- $_ := set $spec "exporter" $exporter }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Append global.imagePullSecrets to the cluster's own list. A name already in
the list is kept once.
*/}}
{{- define "valkey-resources.spec.pullSecrets" -}}
{{- $spec := .spec }}
{{- $globalSecrets := (.root.Values.global | default dict).imagePullSecrets | default list }}
{{- if $globalSecrets }}
{{- $secrets := list }}
{{- if kindIs "slice" $spec.imagePullSecrets }}
{{- $secrets = $spec.imagePullSecrets }}
{{- end }}
{{- $have := dict }}
{{- range $secret := $secrets }}
{{- if kindIs "map" $secret }}
{{- $_ := set $have (toString $secret.name) true }}
{{- end }}
{{- end }}
{{- range $secret := $globalSecrets }}
{{- $entry := ternary $secret (dict "name" $secret) (kindIs "map" $secret) }}
{{- if not (hasKey $have (toString $entry.name)) }}
{{- $secrets = append $secrets $entry }}
{{- $_ := set $have (toString $entry.name) true }}
{{- end }}
{{- end }}
{{- $_ := set $spec "imagePullSecrets" $secrets }}
{{- end }}
{{- end }}

{{/*
Apply cluster.image.pullPolicy and cluster.exporter.image.pullPolicy.
ValkeyCluster has no pull policy field, so they go through the containers
patch, which the operator merges into its containers by name.
*/}}
{{- define "valkey-resources.spec.pullPolicies" -}}
{{- $spec := .spec }}
{{- $values := .root.Values }}
{{- $serverPolicy := ($values.cluster.image | default dict).pullPolicy }}
{{- include "valkey-resources.setPullPolicy" (dict "spec" $spec "container" "server" "policy" $serverPolicy) }}
{{- $exporterPolicy := (($values.cluster.exporter | default dict).image | default dict).pullPolicy }}
{{- $exporter := $spec.exporter | default dict }}
{{- /* A disabled exporter has no base container, so a patch entry for it would become an image-less container */}}
{{- if not (and (kindIs "bool" $exporter.enabled) (not $exporter.enabled)) }}
{{- include "valkey-resources.setPullPolicy" (dict "spec" $spec "container" "metrics-exporter" "policy" $exporterPolicy) }}
{{- end }}
{{- end }}

{{/*
Set imagePullPolicy on the spec.containers entry named "container", or append
{name, imagePullPolicy} when there is none. An imagePullPolicy already on the
entry wins. An empty "policy" does nothing.
*/}}
{{- define "valkey-resources.setPullPolicy" -}}
{{- $spec := .spec }}
{{- $name := .container }}
{{- $policy := .policy }}
{{- if $policy }}
{{- $containers := list }}
{{- if kindIs "slice" $spec.containers }}
{{- $containers = $spec.containers }}
{{- end }}
{{- $found := false }}
{{- range $container := $containers }}
{{- if and (kindIs "map" $container) (eq (toString $container.name) $name) }}
{{- $found = true }}
{{- if not $container.imagePullPolicy }}
{{- $_ := set $container "imagePullPolicy" $policy }}
{{- end }}
{{- end }}
{{- end }}
{{- if not $found }}
{{- $containers = append $containers (dict "name" $name "imagePullPolicy" $policy) }}
{{- end }}
{{- $_ := set $spec "containers" $containers }}
{{- end }}
{{- end }}

{{/*
Treat a null replicas or replicasPerShard as unset, which drops a value reused
from an earlier release. Without either field the operator runs no replicas,
so default replicasPerShard to 1.
*/}}
{{- define "valkey-resources.spec.replicas" -}}
{{- $spec := .spec }}
{{- range $field := list "replicas" "replicasPerShard" }}
{{- if and (hasKey $spec $field) (kindIs "invalid" (get $spec $field)) }}
{{- $_ := unset $spec $field }}
{{- end }}
{{- end }}
{{- if not (or (hasKey $spec "replicas") (hasKey $spec "replicasPerShard")) }}
{{- $_ := set $spec "replicasPerShard" 1 }}
{{- end }}
{{- end }}

{{/*
Point spec.serviceAccountName at the chart's ServiceAccount when
serviceAccount.create or serviceAccount.name is set. An explicit
serviceAccountName wins, but with serviceAccount.create it must match.
*/}}
{{- define "valkey-resources.spec.serviceAccount" -}}
{{- $spec := .spec }}
{{- $root := .root }}
{{- $sa := $root.Values.serviceAccount }}
{{- $chartName := include "valkey-resources.serviceAccountName" $root }}
{{- if and (or $sa.create $sa.name) (not (hasKey $spec "serviceAccountName")) }}
{{- $_ := set $spec "serviceAccountName" $chartName }}
{{- else if $sa.create }}
{{- $specName := tpl (toString $spec.serviceAccountName) $root }}
{{- if ne $specName $chartName }}
{{- fail (printf "cluster.spec.serviceAccountName is %q, so the ServiceAccount %q that serviceAccount.create renders would go unused: remove one of them, or set serviceAccount.name to match" $specName $chartName) }}
{{- end }}
{{- end }}
{{- end }}

{{/*
With usersSecret.create, point the deprecated spec.users at the chart's users
Secret and check that it holds a password for each user that reads it.
*/}}
{{- define "valkey-resources.spec.usersSecret" -}}
{{- $spec := .spec }}
{{- $root := .root }}
{{- if $root.Values.usersSecret.create }}
{{- $secretName := include "valkey-resources.usersSecretName" $root }}
{{- $users := list }}
{{- range $user := ($spec.users | default list) }}
{{- $user = deepCopy $user }}
{{- /* The operator reads no password for these users */}}
{{- if not (or $user.nopass $user.resetpass (and (kindIs "bool" $user.enabled) (not $user.enabled))) }}
{{- $ref := deepCopy (default dict $user.passwordSecret) }}
{{- $refName := tpl (toString (default "" $ref.name)) $root }}
{{- if or (eq $refName "") (eq $refName $secretName) }}
{{- if and $root.Values.usersSecret.name (eq $refName "") }}
{{- $_ := set $ref "name" $secretName }}
{{- $_ := set $user "passwordSecret" $ref }}
{{- end }}
{{- $userName := tpl (toString $user.name) $root }}
{{- range $key := (default (list $userName) $ref.keys) }}
{{- $key = tpl (toString $key) $root }}
{{- if not (hasKey $root.Values.usersSecret.passwords $key) }}
{{- fail (printf "cluster.spec.users %q reads password key %q, but usersSecret.passwords has no entry for it" $userName $key) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- $users = append $users $user }}
{{- end }}
{{- if $spec.users }}
{{- $_ := set $spec "users" $users }}
{{- end }}
{{- end }}
{{- end }}
