{{- define "veeamon-tour.fullname" -}}
{{ .Release.Name }}-veeamon-tour
{{- end -}}

{{- define "veeamon-tour.mariadbHost" -}}
{{ .Release.Name }}-mariadb
{{- end -}}
