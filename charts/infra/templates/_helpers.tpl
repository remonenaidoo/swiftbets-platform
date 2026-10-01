{{- define "infra.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: swiftbets
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
