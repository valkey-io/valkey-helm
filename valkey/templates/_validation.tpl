{{/*
Validate deployment mode configuration
Only ONE mode should be enabled at a time
*/}}
{{- define "valkey.validateMode" -}}
{{- $enabledModes := list -}}
{{- if .Values.standalone.enabled -}}
  {{- $enabledModes = append $enabledModes "standalone" -}}
{{- end -}}
{{- if .Values.sentinel.enabled -}}
  {{- $enabledModes = append $enabledModes "sentinel" -}}
{{- end -}}
{{- if gt (len $enabledModes) 1 -}}
  {{- fail (printf "ERROR: Multiple deployment modes enabled: %s. Only ONE mode can be enabled at a time. Please set only one of standalone.enabled or sentinel.enabled to true." (join ", " $enabledModes)) -}}
{{- end -}}
{{- if eq (len $enabledModes) 0 -}}
  {{- fail "ERROR: No deployment mode enabled. Please set either standalone.enabled=true or sentinel.enabled=true." -}}
{{- end -}}
{{- if .Values.sentinel.enabled -}}
  {{- if lt (int .Values.replicaCount) 3 -}}
    {{- fail (printf "ERROR: Sentinel mode requires at least 3 Valkey replicas for high availability. Current replicaCount is %d. Please set replicaCount to at least 3." (int .Values.replicaCount)) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate ServiceMonitor CRD availability
Check if Prometheus Operator CRDs are installed when ServiceMonitor is enabled
*/}}
{{- define "valkey.validateServiceMonitor" -}}
{{- if and .Values.metrics.enabled .Values.metrics.serviceMonitor.enabled -}}
  {{- if not (.Capabilities.APIVersions.Has "monitoring.coreos.com/v1") -}}
    {{- if .Capabilities.APIVersions.Has "monitoring.coreos.com/v1/ServiceMonitor" -}}
      {{/* CRD exists, continue */}}
    {{- else -}}
      {{- fail "ERROR: ServiceMonitor is enabled but the Prometheus Operator CRDs are not installed. Please install Prometheus Operator first:\n  kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/bundle.yaml\nOr disable ServiceMonitor:\n  --set metrics.serviceMonitor.enabled=false" -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate VolumeSnapshot CRD availability (for future use)
Check if VolumeSnapshot CRDs are installed when volume snapshots are enabled
*/}}
{{- define "valkey.validateVolumeSnapshot" -}}
{{- if .Values.volumeSnapshots -}}
  {{- if .Values.volumeSnapshots.enabled -}}
    {{- if not (.Capabilities.APIVersions.Has "snapshot.storage.k8s.io/v1") -}}
      {{- if .Capabilities.APIVersions.Has "snapshot.storage.k8s.io/v1/VolumeSnapshot" -}}
        {{/* CRD exists, continue */}}
      {{- else -}}
        {{- fail "ERROR: VolumeSnapshot is enabled but the snapshot.storage.k8s.io CRDs are not installed. Please install the volume snapshot CRDs:\n  kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml\nOr disable volume snapshots:\n  --set volumeSnapshots.enabled=false" -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}
