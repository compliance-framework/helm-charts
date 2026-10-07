{{/*
Agent bootstrap: helpers for the optional post-install/post-upgrade Job that creates agent
service accounts and keys in the CCF API and stores each key in a Kubernetes Secret.
*/}}

{{- define "ccf-app.agentBootstrap.name" -}}
{{- printf "%s-agent-bootstrap" (include "ccf-app.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
The agents to bootstrap, validated and with namespace defaulted, as a JSON list.
*/}}
{{- define "ccf-app.agentBootstrap.agents" -}}
{{- $bootstrap := .Values.api.agentBootstrap -}}
{{- $agents := list -}}
{{- $seen := dict -}}
{{- range $i, $agent := (default (list) $bootstrap.agents) -}}
{{- if not $agent.name -}}
{{- fail (printf "api.agentBootstrap.agents[%d].name is required" $i) -}}
{{- end -}}
{{- if not $agent.secretName -}}
{{- fail (printf "api.agentBootstrap.agents[%d].secretName is required" $i) -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$" $agent.secretName) -}}
{{- fail (printf "api.agentBootstrap.agents[%d].secretName %q is not a valid Secret name" $i $agent.secretName) -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9]([A-Za-z0-9 ._-]*[A-Za-z0-9])?$" (toString $agent.name)) -}}
{{- fail (printf "api.agentBootstrap.agents[%d].name %q may only contain letters, digits, spaces, '.', '_' and '-' (and must start and end with a letter or digit)" $i (toString $agent.name)) -}}
{{- end -}}
{{- $namespace := default $.Release.Namespace $agent.namespace -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $namespace) -}}
{{- fail (printf "api.agentBootstrap.agents[%d].namespace %q is not a valid namespace name" $i $namespace) -}}
{{- end -}}
{{- $key := printf "%s/%s" $namespace $agent.secretName -}}
{{- if hasKey $seen $key -}}
{{- fail (printf "api.agentBootstrap.agents: Secret %s is listed twice" $key) -}}
{{- end -}}
{{- $_ := set $seen $key true -}}
{{- $agents = append $agents (dict "name" $agent.name "description" (default "" $agent.description) "secretName" $agent.secretName "namespace" $namespace) -}}
{{- end -}}
{{- if not $agents -}}
{{- fail "api.agentBootstrap.agents must list at least one agent when api.agentBootstrap.enabled is true" -}}
{{- end -}}
{{- toJson $agents -}}
{{- end }}

{{/*
Base URL of the API, including /api.
*/}}
{{- define "ccf-app.agentBootstrap.apiUrl" -}}
{{- $bootstrap := .Values.api.agentBootstrap -}}
{{- if $bootstrap.apiUrl -}}
{{- $bootstrap.apiUrl | trimSuffix "/" -}}
{{- else -}}
{{- if not (and .Values.api.enabled .Values.api.service.enabled) -}}
{{- fail "api.agentBootstrap needs api.enabled and api.service.enabled, or api.agentBootstrap.apiUrl" -}}
{{- end -}}
{{- printf "http://%s-api.%s.svc:%v/api" (include "ccf-app.fullname" .) .Release.Namespace .Values.api.service.port -}}
{{- end -}}
{{- end }}

{{/*
The agents as lines for the script: "<index> <namespace> <secretName> <name>". The name goes
last because it may contain spaces; none of the fields can contain a newline (validated above).
Descriptions are free text and travel in BOOTSTRAP_AGENT_<index>_DESCRIPTION instead.
*/}}
{{- define "ccf-app.agentBootstrap.agentLines" -}}
{{- range $i, $agent := (include "ccf-app.agentBootstrap.agents" . | fromJsonArray) }}
{{ $i }} {{ $agent.namespace }} {{ $agent.secretName }} {{ $agent.name }}
{{- end }}
{{- end }}

{{/*
The bootstrap script: files/agent-bootstrap.sh (kept as a plain file so it is not templated and
can be linted with shellcheck).
*/}}
{{- define "ccf-app.agentBootstrap.script" -}}
{{- .Files.Get "files/agent-bootstrap.sh" -}}
{{- end }}
