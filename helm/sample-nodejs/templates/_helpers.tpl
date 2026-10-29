{{/* Chart name */}}
{{- define "sample-nodejs.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified app name */}}
{{- define "sample-nodejs.fullname" -}}
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

{{- define "sample-nodejs.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Common labels */}}
{{- define "sample-nodejs.labels" -}}
helm.sh/chart: {{ include "sample-nodejs.chart" . }}
{{ include "sample-nodejs.selectorLabels" . }}
app.kubernetes.io/version: {{ include "sample-nodejs.imageTag" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Selector labels (immutable on a Deployment – keep minimal) */}}
{{- define "sample-nodejs.selectorLabels" -}}
app.kubernetes.io/name: {{ include "sample-nodejs.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "sample-nodejs.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "sample-nodejs.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "sample-nodejs.imageTag" -}}
{{- default .Chart.AppVersion .Values.image.tag }}
{{- end }}

{{/* Name of the Secret to load env vars from ("" when none) */}}
{{- define "sample-nodejs.secretName" -}}
{{- if .Values.existingSecret }}
{{- .Values.existingSecret }}
{{- else if .Values.secret }}
{{- include "sample-nodejs.fullname" . }}
{{- end }}
{{- end }}
