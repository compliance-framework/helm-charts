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
Agent hostname. Deprecated: rendered as the HOSTNAME env var, which the agent ignores (it
calls os.Hostname(), the pod name). Kept so existing values render unchanged.
*/}}
{{- define "ccf-agent.hostname" -}}
{{- if .Values.agent.hostname }}
{{- .Values.agent.hostname }}
{{- else }}
{{- include "ccf-agent.fullname" . }}
{{- end }}
{{- end }}

{{/*
UUID pattern shared by the auth and instance ID checks (the agent rejects anything else).
*/}}
{{- define "ccf-agent.uuidPattern" -}}
^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$
{{- end }}

{{/*
Validate agent API authentication configuration.
The agent reads CCF_API_AUTH_CLIENT_ID / CCF_API_AUTH_CLIENT_SECRET, requires both or
neither, and requires the client ID to be a UUID.
*/}}
{{- define "ccf-agent.validateAuthConfig" -}}
{{- if .Values.agent.api.auth.enabled }}
{{- $auth := .Values.agent.api.auth }}
{{- $clientId := default (dict) $auth.clientId }}
{{- $clientSecret := default (dict) $auth.clientSecret }}
{{- if and $auth.createSecret $auth.existingSecret }}
{{- fail "agent.api.auth: cannot set both createSecret and existingSecret" }}
{{- end }}
{{- if $auth.createSecret }}
{{- if not $clientId.value }}
{{- fail "agent.api.auth: when createSecret is true, clientId.value must be set" }}
{{- end }}
{{- if not $clientSecret.value }}
{{- fail "agent.api.auth: when createSecret is true, clientSecret.value must be set" }}
{{- end }}
{{- if or $clientId.secretKeyRef $clientSecret.secretKeyRef }}
{{- fail "agent.api.auth: when createSecret is true, secretKeyRef must not be set" }}
{{- end }}
{{- end }}
{{- if and $clientId.secretKeyRef (not $auth.existingSecret) }}
{{- fail "agent.api.auth: clientId.secretKeyRef requires existingSecret to be set" }}
{{- end }}
{{- if and $clientSecret.secretKeyRef (not $auth.existingSecret) }}
{{- fail "agent.api.auth: clientSecret.secretKeyRef requires existingSecret to be set" }}
{{- end }}
{{- if not $auth.existingSecret }}
{{- if and $clientId.value (not $clientSecret.value) }}
{{- fail "agent.api.auth: clientId.value is set but clientSecret.value is not; the agent needs both or neither" }}
{{- end }}
{{- if and $clientSecret.value (not $clientId.value) }}
{{- fail "agent.api.auth: clientSecret.value is set but clientId.value is not; the agent needs both or neither" }}
{{- end }}
{{- if and $clientId.value (not (regexMatch (include "ccf-agent.uuidPattern" .) $clientId.value)) }}
{{- fail "agent.api.auth: clientId.value must be a UUID (the client-id of an agent key from the CCF API)" }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
API credential env vars for the agent container. With existingSecret, the keys default to
CCF_API_AUTH_CLIENT_ID / CCF_API_AUTH_CLIENT_SECRET (the keys the ccf-app agent bootstrap Job
writes); clientId.secretKeyRef / clientSecret.secretKeyRef override them.
*/}}
{{- define "ccf-agent.authEnv" -}}
{{- $auth := .Values.agent.api.auth }}
{{- if $auth.enabled }}
{{- $clientId := default (dict) $auth.clientId }}
{{- $clientSecret := default (dict) $auth.clientSecret }}
{{- if $auth.existingSecret }}
- name: CCF_API_AUTH_CLIENT_ID
  valueFrom:
    secretKeyRef:
      name: {{ $auth.existingSecret }}
      key: {{ default "CCF_API_AUTH_CLIENT_ID" $clientId.secretKeyRef }}
- name: CCF_API_AUTH_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ $auth.existingSecret }}
      key: {{ default "CCF_API_AUTH_CLIENT_SECRET" $clientSecret.secretKeyRef }}
{{- else if $auth.createSecret }}
- name: CCF_API_AUTH_CLIENT_ID
  valueFrom:
    secretKeyRef:
      name: {{ include "ccf-agent.fullname" . }}-auth
      key: CCF_API_AUTH_CLIENT_ID
- name: CCF_API_AUTH_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "ccf-agent.fullname" . }}-auth
      key: CCF_API_AUTH_CLIENT_SECRET
{{- else if and $clientId.value $clientSecret.value }}
- name: CCF_API_AUTH_CLIENT_ID
  value: {{ $clientId.value | quote }}
- name: CCF_API_AUTH_CLIENT_SECRET
  value: {{ $clientSecret.value | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Agent state directory. Pinned so the state key does not depend on the config file path;
it lives on the ccf-tmp emptyDir mounted at /app/.compliance-framework.
*/}}
{{- define "ccf-agent.stateDir" -}}
/app/.compliance-framework/state/agent
{{- end }}

{{/*
Validate the optional agent instance ID (the agent refuses anything but a UUID).
*/}}
{{- define "ccf-agent.validateInstanceId" -}}
{{- with .Values.agent.instanceId }}
{{- if not (regexMatch (include "ccf-agent.uuidPattern" $) .) }}
{{- fail "agent.instanceId must be a UUID" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Total seconds of a Go duration string such as 1m30s (no sign). Used to enforce
remote_config.poll_interval >= 15s, which the agent requires.
*/}}
{{- define "ccf-agent.durationSeconds" -}}
{{- $units := dict "ns" 0.000000001 "us" 0.000001 "µs" 0.000001 "ms" 0.001 "s" 1.0 "m" 60.0 "h" 3600.0 -}}
{{- $total := 0.0 -}}
{{- range (regexFindAll "[0-9]*[.]?[0-9]+(ns|us|µs|ms|s|m|h)" . -1) -}}
{{- $num := regexFind "^[0-9]*[.]?[0-9]+" . | float64 -}}
{{- $unit := regexReplaceAll "^[0-9]*[.]?[0-9]+" . "" -}}
{{- $total = addf $total (mulf $num (get $units $unit)) -}}
{{- end -}}
{{- $total -}}
{{- end }}

{{/*
The agent's remote_config block as YAML, with only the keys that are set. Empty when
nothing is set, so the agent defaults apply.
*/}}
{{- define "ccf-agent.remoteConfig" -}}
{{- $in := default (dict) .Values.agent.remoteConfig -}}
{{- $rc := dict -}}
{{- with $in.mode }}
{{- $_ := set $rc "mode" (toString .) -}}
{{- end }}
{{- with $in.pollInterval }}
{{- if not (regexMatch "^([0-9]*[.]?[0-9]+(ns|us|µs|ms|s|m|h))+$" .) }}
{{- fail (printf "agent.remoteConfig.pollInterval %q is not a Go duration such as 60s or 5m" .) }}
{{- end }}
{{- if lt (include "ccf-agent.durationSeconds" . | float64) 15.0 }}
{{- fail (printf "agent.remoteConfig.pollInterval %q must be at least 15s" .) }}
{{- end }}
{{- $_ := set $rc "poll_interval" . -}}
{{- end }}
{{- with $in.trustedSources }}
{{- $_ := set $rc "trusted_sources" . -}}
{{- end }}
{{- with $in.overridableConfigFlags }}
{{- $_ := set $rc "overridable_config_flags" . -}}
{{- end }}
{{- if not (kindIs "invalid" $in.allowLocalSources) }}
{{- $_ := set $rc "allow_local_sources" $in.allowLocalSources -}}
{{- end }}
{{- if $rc }}
{{- toYaml $rc }}
{{- end }}
{{- end }}

{{/*
How the agent gets its API credentials, for NOTES. Empty when it runs anonymously.
*/}}
{{- define "ccf-agent.authSource" -}}
{{- $auth := .Values.agent.api.auth -}}
{{- if $auth.enabled -}}
{{- if $auth.existingSecret -}}
existing secret {{ $auth.existingSecret }}
{{- else if $auth.createSecret -}}
chart secret {{ include "ccf-agent.fullname" . }}-auth
{{- else if and $auth.clientId.value $auth.clientSecret.value -}}
inline values
{{- end -}}
{{- end -}}
{{- end }}
