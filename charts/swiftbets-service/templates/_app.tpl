{{/*
Renders one service. Call from a service chart's template with: {{ include "swiftbets-service.app" . }}
*/}}
{{- define "swiftbets-service.app" -}}
{{- $name := include "swiftbets-service.name" . -}}
{{- $v := .Values -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $name }}
  labels:
    {{- include "swiftbets-service.labels" . | nindent 4 }}
    app.kubernetes.io/component: {{ $v.component | default "api" }}
spec:
  {{- if not (dig "enabled" false ($v.autoscaling | default dict)) }}
  replicas: {{ $v.replicas | default 1 }}
  {{- end }}
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      {{- include "swiftbets-service.selector" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "swiftbets-service.selector" . | nindent 8 }}
        app.kubernetes.io/part-of: swiftbets
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: {{ $v.port | default 8080 | quote }}
        prometheus.io/path: {{ $v.metricsPath | default "/metrics" | quote }}
    spec:
      automountServiceAccountToken: false
      enableServiceLinks: false
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      terminationGracePeriodSeconds: {{ $v.terminationGracePeriodSeconds | default 30 }}
      containers:
        - name: {{ $name }}
          image: {{ include "swiftbets-service.image" (dict "root" . "image" $v.image) }}
          imagePullPolicy: {{ $v.image.pullPolicy | default (dig "imagePullPolicy" "IfNotPresent" (.Values.global | default dict)) }}
          {{- with $v.args }}
          args: {{- toYaml . | nindent 12 }}
          {{- end }}
          ports:
            - name: http
              containerPort: {{ $v.port | default 8080 }}
            {{- if $v.grpcPort }}
            - name: grpc
              containerPort: {{ $v.grpcPort }}
            {{- end }}
          env:
            {{- include "swiftbets-service.env" (dict "root" . "env" $v.env "secretEnv" $v.secretEnv) | nindent 12 }}
          {{- if ne ($v.probes | default "dotnet") "none" }}
          startupProbe:
            httpGet: { path: {{ dig "live" "/health/live" ($v.health | default dict) }}, port: http }
            periodSeconds: 3
            failureThreshold: 60
          livenessProbe:
            httpGet: { path: {{ dig "live" "/health/live" ($v.health | default dict) }}, port: http }
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet: { path: {{ dig "ready" "/health/ready" ($v.health | default dict) }}, port: http }
            periodSeconds: 5
            failureThreshold: 3
          {{- end }}
          {{- with $v.volumes }}
          volumeMounts:
            {{- range . }}
            - { name: {{ .name }}, mountPath: {{ .mountPath }} }
            {{- end }}
          {{- end }}
          resources:
            {{- toYaml ($v.resources | default dict) | nindent 12 }}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: {{ $v.readOnlyRootFilesystem | default false }}
            capabilities:
              drop: ["ALL"]
      {{- with $v.volumes }}
      # A volume claim when one is named, otherwise scratch space that lives as long as the pod.
      volumes:
        {{- range . }}
        - name: {{ .name }}
          {{- if .claimName }}
          persistentVolumeClaim: { claimName: {{ .claimName }} }
          {{- else }}
          emptyDir: {}
          {{- end }}
        {{- end }}
      {{- end }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $name }}
  labels:
    {{- include "swiftbets-service.labels" . | nindent 4 }}
spec:
  selector:
    {{- include "swiftbets-service.selector" . | nindent 4 }}
  ports:
    - name: http
      port: {{ $v.servicePort | default 8080 }}
      targetPort: http
    {{- if $v.grpcPort }}
    - name: grpc
      port: {{ $v.grpcPort }}
      targetPort: grpc
      appProtocol: kubernetes.io/h2c
    {{- end }}
{{- if dig "enabled" false ($v.autoscaling | default dict) }}
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ $name }}
  labels:
    {{- include "swiftbets-service.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ $name }}
  minReplicas: {{ $v.autoscaling.minReplicas | default 2 }}
  maxReplicas: {{ $v.autoscaling.maxReplicas | default 6 }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ $v.autoscaling.cpuPercent | default 70 }}
{{- end }}
{{- if dig "enabled" false ($v.pdb | default dict) }}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ $name }}
  labels:
    {{- include "swiftbets-service.labels" . | nindent 4 }}
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      {{- include "swiftbets-service.selector" . | nindent 6 }}
{{- end }}
{{- range $migrator := $v.migrators | default list }}
---
{{ include "swiftbets-service.migrator" (dict "root" $ "migrator" $migrator) }}
{{- end }}
{{- end -}}
