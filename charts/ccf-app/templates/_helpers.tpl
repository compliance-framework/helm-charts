{{/*
Expand the name of the chart.
*/}}
{{- define "ccf-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "ccf-app.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "ccf-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "ccf-app.labels" -}}
helm.sh/chart: {{ include "ccf-app.chart" . }}
{{ include "ccf-app.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "ccf-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ccf-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "ccf-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "ccf-app.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return a base64 encoded database password. If the release already has a secret,
reuse its password to keep credentials stable across upgrades; otherwise generate
and return a new random password.
*/}}
{{- define "ccf-app.psqlPasswordB64" -}}
{{- $secretName := printf "%s-psql" (include "ccf-app.fullname" .) -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $secretName -}}
{{- if and $existing (index $existing.data "POSTGRES_PASSWORD") -}}
{{- index $existing.data "POSTGRES_PASSWORD" -}}
{{- else if .Values.database.local.password -}}
{{- trim .Values.database.local.password | b64enc -}}
{{- else -}}
{{- randAlphaNum 32 | b64enc -}}
{{- end -}}
{{- end -}}

{{- define "ccf-app.initialUserPasword" -}}
{{- $secretName := printf "%s-initial-user-password" (include "ccf-app.fullname" .) -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $secretName -}}
{{- if and $existing (index $existing.data "password") -}}
{{- index $existing.data "password" -}}
{{- else if .Values.api.user.password -}}
{{- trim .Values.database.user.password | b64enc -}}
{{- else -}}
{{- randAlphaNum 12 | b64enc -}}
{{- end -}}
{{- end -}}