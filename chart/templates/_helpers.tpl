{{- define "minecraft-java.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "minecraft-java.fullname" -}}
{{- default (include "minecraft-java.name" .) .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "minecraft-java.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "minecraft-java.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "minecraft-java.selectorLabels" -}}
app.kubernetes.io/name: {{ include "minecraft-java.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
