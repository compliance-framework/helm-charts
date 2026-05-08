{{/*
Expand the name of the chart.
*/}}
{{- define "ccf-agent.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "ccf-agent.fullname" -}}
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
{{- define "ccf-agent.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "ccf-agent.labels" -}}
helm.sh/chart: {{ include "ccf-agent.chart" . }}
{{ include "ccf-agent.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "ccf-agent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ccf-agent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "ccf-agent.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "ccf-agent.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Agent hostname - defaults to pod name if not specified
*/}}
{{- define "ccf-agent.hostname" -}}
{{- if .Values.agent.hostname }}
{{- .Values.agent.hostname }}
{{- else }}
{{- include "ccf-agent.fullname" . }}
{{- end }}
{{- end }}

{{/*
Validate agent API authentication configuration
*/}}
{{- define "ccf-agent.validateAuthConfig" -}}
{{- if .Values.agent.api.auth.enabled }}
{{- $auth := .Values.agent.api.auth }}
{{- if and $auth.createSecret $auth.existingSecret }}
{{- fail "agent.api.auth: cannot set both createSecret and existingSecret" }}
{{- end }}
{{- if $auth.createSecret }}
{{- if not $auth.clientId.value }}
{{- fail "agent.api.auth: when createSecret is true, clientId.value must be set" }}
{{- end }}
{{- if not $auth.clientSecret.value }}
{{- fail "agent.api.auth: when createSecret is true, clientSecret.value must be set" }}
{{- end }}
{{- if or $auth.clientId.secretKeyRef $auth.clientSecret.secretKeyRef }}
{{- fail "agent.api.auth: when createSecret is true, secretKeyRef must not be set" }}
{{- end }}
{{- end }}
{{- if and $auth.clientId.secretKeyRef (not $auth.existingSecret) }}
{{- fail "agent.api.auth: clientId.secretKeyRef requires existingSecret to be set" }}
{{- end }}
{{- if and $auth.clientSecret.secretKeyRef (not $auth.existingSecret) }}
{{- fail "agent.api.auth: clientSecret.secretKeyRef requires existingSecret to be set" }}
{{- end }}
{{- if $auth.existingSecret }}
{{- if $auth.clientId }}
{{- if not $auth.clientId.secretKeyRef }}
{{- fail "agent.api.auth: when existingSecret is set, clientId.secretKeyRef must be set" }}
{{- end }}
{{- end }}
{{- if $auth.clientSecret }}
{{- if not $auth.clientSecret.secretKeyRef }}
{{- fail "agent.api.auth: when existingSecret is set, clientSecret.secretKeyRef must be set" }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
