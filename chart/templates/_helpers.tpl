{{- define "demo.name" -}}
{{ .Release.Name }}-{{ .Chart.Name }}
{{- end -}}

{{- define "demo.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
