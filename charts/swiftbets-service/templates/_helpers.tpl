{{/* The Service name is the chart name, unprefixed: services address each other as http://<name>:8080 everywhere. */}}
{{- define "swiftbets-service.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "swiftbets-service.labels" -}}
app.kubernetes.io/name: {{ include "swiftbets-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: swiftbets
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "swiftbets-service.selector" -}}
app.kubernetes.io/name: {{ include "swiftbets-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* registry/repository:tag, with the umbrella's global registry and tag as defaults. */}}
{{- define "swiftbets-service.image" -}}
{{- $global := .root.Values.global | default dict -}}
{{- $registry := .image.registry | default $global.imageRegistry | default "ghcr.io/remonenaidoo" -}}
{{- $tag := .image.tag | default $global.imageTag | default "main" -}}
{{- printf "%s/%s:%s" $registry .image.repository $tag -}}
{{- end -}}

{{/* Plain env from a map, then secret-backed env: NAME: {secret, key}. Global env first so a service can override it. */}}
{{- define "swiftbets-service.env" -}}
{{- $global := .root.Values.global | default dict -}}
{{- $env := merge (deepCopy (.env | default dict)) (deepCopy ($global.env | default dict)) -}}
{{- range $name := keys $env | sortAlpha }}
- name: {{ $name }}
  value: {{ get $env $name | toString | quote }}
{{- end }}
{{- $secretEnv := .secretEnv | default dict -}}
{{- range $name := keys $secretEnv | sortAlpha }}
{{- $ref := get $secretEnv $name }}
- name: {{ $name }}
  valueFrom:
    secretKeyRef:
      name: {{ $ref.secret | default ($global.secretName | default "swiftbets-secrets") }}
      key: {{ $ref.key }}
{{- end }}
{{- end -}}
