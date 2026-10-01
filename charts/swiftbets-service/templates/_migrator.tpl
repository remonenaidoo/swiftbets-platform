{{/*
A schema migration Job. It is a plain Job named per release revision, not a pre-install hook: in local installs the
database lives in the same release, and a hook would run before it exists. The Job retries until the database is up;
services wait on readiness, which fails until their schema is in place.
*/}}
{{- define "swiftbets-service.migrator" -}}
{{- $root := .root -}}
{{- $m := .migrator -}}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ $m.name }}-r{{ $root.Release.Revision }}
  labels:
    {{- include "swiftbets-service.labels" $root | nindent 4 }}
    app.kubernetes.io/component: migrator
spec:
  backoffLimit: 30
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/part-of: swiftbets
        app.kubernetes.io/component: migrator
    spec:
      restartPolicy: OnFailure
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: migrate
          image: {{ include "swiftbets-service.image" (dict "root" $root "image" $m.image) }}
          imagePullPolicy: {{ $m.image.pullPolicy | default (dig "imagePullPolicy" "IfNotPresent" ($root.Values.global | default dict)) }}
          env:
            {{- include "swiftbets-service.env" (dict "root" $root "env" $m.env "secretEnv" $m.secretEnv) | nindent 12 }}
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits: { memory: 384Mi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
{{- end -}}
