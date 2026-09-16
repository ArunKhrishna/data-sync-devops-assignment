{{/* Chart name. Can be changed with nameOverride. */}}
{{- define "data-sync.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Full resource name. If the release name already contains the chart name, use it as is. */}}
{{- define "data-sync.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/* Chart name and version, used in the helm.sh/chart label. */}}
{{- define "data-sync.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "data-sync.labels" -}}
helm.sh/chart: {{ include "data-sync.chart" . }}
{{ include "data-sync.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/part-of: seo-analytics
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Selector labels. Do not change these after the first install, selectors are immutable. */}}
{{- define "data-sync.selectorLabels" -}}
app.kubernetes.io/name: {{ include "data-sync.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Resolves the ServiceAccount name from the serviceAccount.create/name toggles. */}}
{{- define "data-sync.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "data-sync.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Secret holding REDIS_PASSWORD. Uses existingSecret when set. */}}
{{- define "data-sync.secretName" -}}
{{- if .Values.secret.existingSecret }}
{{- .Values.secret.existingSecret }}
{{- else }}
{{- include "data-sync.fullname" . }}
{{- end }}
{{- end }}
