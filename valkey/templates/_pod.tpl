{{/*
Pod template shared by the standalone Deployment and the replicated
StatefulSet, so that an option added to one cannot silently miss the other.
The parts that only apply to one mode are gated on replica.enabled (and on
replica.sentinel.enabled, which the validation only allows with replication).
Include it under the workload's spec.template with nindent 4.
*/}}
{{- define "valkey.podTemplate" -}}
{{- $replicated := .Values.replica.enabled }}
{{- $sentinel := and $replicated .Values.replica.sentinel.enabled }}
{{- $preStopFailover := and $sentinel .Values.replica.sentinel.preStopFailover }}
{{- $storage := .Values.dataStorage }}
{{- $createPVC := and $storage.enabled (not (empty $storage.requestedSize)) (empty $storage.persistentVolumeClaimName) }}
{{- /* The StatefulSet's volumeClaimTemplate is always named valkey-data */}}
{{- $dataVolume := ternary "valkey-data" $storage.volumeName $replicated -}}
metadata:
  labels:
    {{- include "valkey.selectorLabels" . | nindent 4 }}
    {{- with .Values.commonLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    {{- with .Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  annotations:
    {{- with .Values.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    checksum/initconfig: {{ include (print $.Template.BasePath "/init_config.yaml") . | sha256sum | trunc 32 | quote }}
    {{- if .Values.valkeyConfig }}
    checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum | trunc 32 | quote }}
    {{- end }}
    {{- with (include "valkey.authSecretChecksum" .) }}
    checksum/secret: {{ . | quote }}
    {{- end }}
spec:
  {{- include "valkey.imagePullSecrets" . | nindent 2 }}
  terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
  automountServiceAccountToken: {{ .Values.serviceAccount.automount }}
  serviceAccountName: {{ include "valkey.serviceAccountName" . }}
  {{- if .Values.priorityClassName }}
  priorityClassName: {{ .Values.priorityClassName | quote }}
  {{- end }}
  {{- if .Values.runtimeClassName }}
  runtimeClassName: {{ .Values.runtimeClassName | quote }}
  {{- end }}
  securityContext:
    {{- toYaml .Values.podSecurityContext | nindent 4 }}
  initContainers:
    - name: {{ include "valkey.fullnameWithSuffix" (list . "init") }}
      image: {{ include "valkey.initContainer.image" . }}
      imagePullPolicy: {{ .Values.initContainer.image.pullPolicy | default .Values.image.pullPolicy }}
      {{- with .Values.securityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      command: [ "/scripts/init.sh" ]
      {{- if $replicated }}
      env:
        - name: POD_INDEX
          valueFrom:
            fieldRef:
              fieldPath: metadata.labels['apps.kubernetes.io/pod-index']
        # Where the ordinal comes from when the pod-index label is missing
        # (Kubernetes < 1.28); unlike HOSTNAME, always set and never an FQDN
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
      {{- end }}
      volumeMounts:
        - name: {{ $dataVolume }}
          mountPath: /data
          {{- if and (not $replicated) $storage.subPath }}
          subPath: {{ $storage.subPath }}
          {{- end }}
        - name: valkey-conf
          mountPath: /valkey-conf
        - name: scripts
          mountPath: /scripts
        {{- if $sentinel }}
        - name: sentinel-auth
          mountPath: /sentinel-auth
          readOnly: true
        {{- end }}
        {{- if and .Values.tls.enabled $sentinel }}
        # This container asks Sentinel which node is the master, and over
        # TLS that query needs the CA to verify the answer. Without Sentinel
        # it makes no connection at all, so it gets no key material.
        - name: {{ include "valkey.fullnameWithSuffix" (list . "tls") }}
          mountPath: /tls
          readOnly: true
        {{- end }}
        {{- if .Values.valkeyConfig }}
        - name: valkey-config
          mountPath: /usr/local/etc/valkey/valkey.conf
          subPath: valkey.conf
        {{- end }}
        {{- if .Values.extraSecretValkeyConfigs }}
        - name: extravalkeyconfigs-volume
          mountPath: /extravalkeyconfigs
        {{- end }}
        {{- if .Values.auth.enabled }}
        - name: valkey-acl
          mountPath: /etc/valkey
        {{- if .Values.auth.usersExistingSecret }}
        - name: valkey-users-secret
          mountPath: /valkey-users-secret
          readOnly: true
        {{- end }}
        {{- if (include "valkey.renderAuthSecret" .) | eq "true" }}
        - name: valkey-auth-secret
          mountPath: /valkey-auth-secret
          readOnly: true
        {{- end }}
        {{- end }}
        {{- /* Only the Deployment adds extraVolumeMounts to the init container, on purpose */}}
        {{- if not $replicated }}
        {{- with .Values.extraVolumeMounts }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
        {{- end }}
      {{- with .Values.initResources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
  {{- with .Values.extraInitContainers }}
  {{- toYaml . | nindent 4 }}
  {{- end }}
  containers:
    - name: {{ include "valkey.fullname" . }}
      image: {{ include "valkey.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      {{- if $sentinel }}
      # A wrapper that keeps the credential free master record on the data
      # volume in step with the config Sentinel makes the server rewrite.
      # It execs the server, so valkey-server is still PID 1.
      command: [ "/scripts/valkey-start.sh" ]
      {{- else }}
      command: [ "valkey-server" ]
      {{- end }}
      args: [ "/valkey-conf/valkey.conf" ]
      securityContext:
        {{- toYaml .Values.securityContext | nindent 8 }}
      env:
        {{- if $replicated }}
        - name: POD_INDEX
          valueFrom:
            fieldRef:
              fieldPath: metadata.labels['apps.kubernetes.io/pod-index']
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        {{- end }}
        {{- range $key, $val := .Values.env }}
        - name: {{ $key }}
          value: {{ $val | quote }}
        {{- end }}
      ports:
        - name: tcp
          containerPort: {{ .Values.service.port }}
          protocol: TCP
      {{- with (include "valkey.healthProbes" .) }}
      {{- . | nindent 6 }}
      {{- end }}
      {{- if $preStopFailover }}
      lifecycle:
        preStop:
          exec:
            command: [ "/sentinel-scripts/sentinel-prestop.sh" ]
      {{- end }}
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      volumeMounts:
        - name: {{ $dataVolume }}
          mountPath: /data
          {{- if and (not $replicated) $storage.subPath }}
          subPath: {{ $storage.subPath }}
          {{- end }}
        - name: valkey-conf
          mountPath: /valkey-conf
        {{- if $sentinel }}
        - name: scripts
          mountPath: /scripts
        {{- end }}
        {{- if $preStopFailover }}
        - name: sentinel-scripts
          mountPath: /sentinel-scripts
        - name: sentinel-auth
          mountPath: /sentinel-auth
          readOnly: true
        {{- end }}
        {{- if .Values.tls.enabled }}
        - name: {{ include "valkey.fullnameWithSuffix" (list . "tls") }}
          mountPath: /tls
        {{- end }}
        {{- if .Values.auth.enabled }}
        - name: valkey-acl
          mountPath: /etc/valkey
        {{- if $preStopFailover }}
        {{- if .Values.auth.usersExistingSecret }}
        - name: valkey-users-secret
          mountPath: /valkey-users-secret
          readOnly: true
        {{- end }}
        {{- if (include "valkey.renderAuthSecret" .) | eq "true" }}
        - name: valkey-auth-secret
          mountPath: /valkey-auth-secret
          readOnly: true
        {{- end }}
        {{- end }}
        {{- end }}
        {{- range $secret := .Values.extraValkeySecrets }}
        - name: {{ $secret.name }}-valkey
          mountPath: {{ $secret.mountPath }}
        {{- end }}
        {{- range $config := .Values.extraValkeyConfigs }}
        - name: {{ $config.name }}-valkey
          mountPath: {{ $config.mountPath }}
        {{- end }}
        {{- with .Values.extraVolumeMounts }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    {{- if .Values.metrics.enabled }}
    - name: metrics
      image: {{ include "valkey.metrics.exporter.image" . }}
      imagePullPolicy: {{ .Values.metrics.exporter.image.pullPolicy | quote }}
      {{- with .Values.metrics.exporter.securityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.metrics.exporter.command }}
      command:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.metrics.exporter.args }}
      args:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      ports:
        - name: metrics
          containerPort: {{ .Values.metrics.exporter.port }}
      startupProbe:
        tcpSocket:
          port: metrics
      livenessProbe:
        tcpSocket:
          port: metrics
      readinessProbe:
        httpGet:
          path: /
          port: metrics
      {{- with .Values.metrics.exporter.resources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- $exporterEnvs := .Values.metrics.exporter.extraEnvs | default dict }}
      {{- /* A /tls mount the user already added through extraVolumeMounts
             (the workaround before the chart mounted it) takes the place of
             the chart's own, as Kubernetes rejects a repeated mountPath */}}
      {{- $exporterTlsMount := .Values.tls.enabled }}
      {{- range .Values.metrics.exporter.extraVolumeMounts }}
      {{- if eq (.mountPath | toString | trimSuffix "/") "/tls" }}
      {{- $exporterTlsMount = false }}
      {{- end }}
      {{- end }}
      {{- if or .Values.metrics.exporter.extraVolumeMounts $exporterTlsMount }}
      volumeMounts:
        {{- if $exporterTlsMount }}
        - name: {{ include "valkey.fullnameWithSuffix" (list . "tls") }}
          mountPath: /tls
        {{- end }}
        {{- with .Values.metrics.exporter.extraVolumeMounts }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- end }}
      env:
        - name: REDIS_ALIAS
          value: {{ include "valkey.fullname" . }}
        {{- /* A variable also set in metrics.exporter.extraEnvs is left to that
               entry, so the container never carries the same name twice */}}
        {{- if not (hasKey $exporterEnvs "REDIS_ADDR") }}
        - name: REDIS_ADDR
          value: {{ printf "%s://localhost:%v" (ternary "rediss" "redis" .Values.tls.enabled) .Values.service.port | quote }}
        {{- end }}
        {{- if .Values.tls.enabled }}
        {{- $tlsEnvs := dict
              "REDIS_EXPORTER_TLS_CA_CERT_FILE" (printf "/tls/%s" .Values.tls.caPublicKey)
              "REDIS_EXPORTER_TLS_CLIENT_CERT_FILE" (printf "/tls/%s" .Values.tls.serverPublicKey)
              "REDIS_EXPORTER_TLS_CLIENT_KEY_FILE" (printf "/tls/%s" .Values.tls.serverKey)
              "REDIS_EXPORTER_TLS_SERVER_NAME" (.Values.metrics.exporter.tlsServerName | default (include "valkey.fullname" .)) }}
        {{- range $name := list "REDIS_EXPORTER_TLS_CA_CERT_FILE" "REDIS_EXPORTER_TLS_CLIENT_CERT_FILE" "REDIS_EXPORTER_TLS_CLIENT_KEY_FILE" "REDIS_EXPORTER_TLS_SERVER_NAME" }}
        {{- if not (hasKey $exporterEnvs $name) }}
        - name: {{ $name }}
          value: {{ index $tlsEnvs $name | quote }}
        {{- end }}
        {{- end }}
        {{- end }}
        {{- if .Values.auth.enabled }}
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              {{- if .Values.auth.usersExistingSecret }}
              {{- $defaultUser := index .Values.auth.aclUsers "default" | default dict }}
              {{- $passwordKey := $defaultUser.passwordKey | default "default" }}
              name: {{ tpl .Values.auth.usersExistingSecret . }}
              key: {{ $passwordKey }}
              {{- else }}
              name: {{ include "valkey.fullname" . }}-auth
              key: default-password
              {{- end }}
        {{- end }}
        {{- range $key, $val := .Values.metrics.exporter.extraEnvs }}
        - name: {{ $key }}
          value: {{ $val | quote }}
        {{- end }}
    {{- end }}
  {{- with .Values.extraContainers }}
  {{- toYaml . | nindent 4 }}
  {{- end }}
  volumes:
    # Holds valkey.conf, which init.sh generates there. Memory backed
    # because the file carries credentials in plain text, and with
    # replication CONFIG REWRITE rewrites them into it whenever Sentinel
    # changes the topology.
    - name: valkey-conf
      emptyDir:
        medium: Memory
    - name: scripts
      configMap:
        name: {{ include "valkey.fullname" . }}-init-scripts
        defaultMode: 0555
    {{- if $sentinel }}
    - name: sentinel-scripts
      configMap:
        name: {{ include "valkey.fullname" . }}-sentinel-scripts
        defaultMode: 0555
    - name: sentinel-auth
      projected:
        defaultMode: 0400
        sources:
          {{- if .Values.auth.usersExistingSecret }}
          - secret:
              name: {{ tpl .Values.auth.usersExistingSecret . }}
              optional: true
              items:
                - key: {{ .Values.replica.sentinel.passwordKey }}
                  path: existing-password
          {{- end }}
          {{- if .Values.replica.sentinel.password }}
          - secret:
              name: {{ include "valkey.fullname" . }}-auth
              optional: true
              items:
                - key: sentinel-password
                  path: inline-password
          {{- end }}
    {{- end }}
    {{- if .Values.auth.enabled }}
    - name: valkey-acl
      emptyDir:
        medium: Memory
    {{- end }}
    {{- if .Values.valkeyConfig }}
    - name: valkey-config
      configMap:
        name: {{ include "valkey.fullname" . }}-config
    {{- end }}
    {{- range .Values.extraValkeySecrets }}
    - name: {{ .name }}-valkey
      secret:
        secretName: {{ .name }}
        defaultMode: {{ .defaultMode | default 0440 }}
    {{- end }}
    {{- if .Values.tls.enabled }}
    - name: {{ include "valkey.fullnameWithSuffix" (list . "tls") }}
      secret:
        secretName: {{ required "An existing secret is required to enable TLS" .Values.tls.existingSecret }}
        defaultMode: 0400
    {{- end }}
    {{- range .Values.extraValkeyConfigs }}
    - name: {{ .name }}-valkey
      configMap:
        name: {{ .name }}
        defaultMode: {{ .defaultMode | default 0440 }}
    {{- end }}
    {{- if .Values.metrics.enabled }}
    {{- range .Values.metrics.exporter.extraExporterSecrets }}
    - name: {{ .name }}-exporter
      secret:
        secretName: {{ .name }}
        defaultMode: {{ .defaultMode | default 0440 }}
    {{- end }}
    {{- end }}
    {{- if .Values.auth.enabled }}
    {{- if .Values.auth.usersExistingSecret }}
    - name: valkey-users-secret
      secret:
        secretName: {{ tpl .Values.auth.usersExistingSecret . }}
        defaultMode: 0400
    {{- end }}
    {{- if (include "valkey.renderAuthSecret" .) | eq "true" }}
    - name: valkey-auth-secret
      secret:
        secretName: {{ include "valkey.fullname" . }}-auth
        defaultMode: 0400
    {{- end }}
    {{- end }}
    {{- /* The StatefulSet provides the data volume through its volumeClaimTemplate */}}
    {{- if not $replicated }}
    - name: {{ $dataVolume }}
    {{- if $storage.persistentVolumeClaimName }}
      persistentVolumeClaim:
        claimName: {{ $storage.persistentVolumeClaimName }}
    {{- else if $createPVC }}
      persistentVolumeClaim:
        claimName: {{ include "valkey.fullname" . }}
    {{- else if $storage.hostPath }}
      hostPath:
        path: {{ $storage.hostPath }}
        type: DirectoryOrCreate
    {{- else }}
      emptyDir: {}
    {{- end }}
    {{- end }}
    {{- with .Values.extraVolumes }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.topologySpreadConstraints }}
  topologySpreadConstraints:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}
