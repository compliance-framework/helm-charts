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
{{- $namespace := default $.Release.Namespace $agent.namespace -}}
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
The bootstrap script (POSIX sh). It never prints a password, token or client secret: request
bodies and the Authorization header are passed to curl through files and stdin, not argv, and
only non-2xx response bodies (error messages) are logged.
*/}}
{{- define "ccf-app.agentBootstrap.script" -}}
set -eu

log() { echo "agent-bootstrap: $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  if command -v apk >/dev/null 2>&1; then
    log "installing curl and jq"
    apk add --no-cache curl jq >/dev/null || die "could not install curl and jq"
  else
    die "the image needs curl and jq"
  fi
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
umask 077

api="${BOOTSTRAP_API_URL%/}"
sa=/var/run/secrets/kubernetes.io/serviceaccount
k8s="https://kubernetes.default.svc"
printf 'Authorization: Bearer %s\n' "$(cat "$sa/token")" > "$work/k8s-auth"

# http METHOD URL AUTHFILE [BODYFILE]: sets STATUS and writes the response body to $work/body.
# The Kubernetes API is verified with the service account CA; the CCF API with the system CAs.
http() {
  url="$2"; data="${4:-}"
  set -- -sS -o "$work/body" -w '%{http_code}' -X "$1" "$url" -H "@$3"
  case "$url" in "$k8s"/*) set -- "$@" --cacert "$sa/ca.crt" ;; esac
  if [ -n "$data" ]; then
    set -- "$@" -H 'Content-Type: application/json' --data-binary "@$data"
  fi
  STATUS="$(curl "$@")" || STATUS=000
}

# 1. Wait for the API to be ready.
deadline=$(( $(date +%s) + ${BOOTSTRAP_WAIT_SECONDS:-300} ))
log "waiting for $api/health/ready"
until curl -fsS -o /dev/null "$api/health/ready" 2>/dev/null; do
  [ "$(date +%s)" -lt "$deadline" ] || die "the API was not ready within ${BOOTSTRAP_WAIT_SECONDS:-300}s"
  sleep 5
done

# 2. Log in as the admin user.
jq -n '{email: env.ADMIN_EMAIL, password: env.ADMIN_PASSWORD}' > "$work/login.json"
: > "$work/no-auth"
http POST "$api/auth/login" "$work/no-auth" "$work/login.json"
rm -f "$work/login.json"
[ "$STATUS" = 200 ] || die "POST /api/auth/login as $ADMIN_EMAIL returned $STATUS"
token="$(jq -r '.data.auth_token // empty' "$work/body")"
[ -n "$token" ] || die "POST /api/auth/login returned no token"
printf 'Authorization: Bearer %s\n' "$token" > "$work/api-auth"
unset token

# 3. One agent, key and Secret per entry.
printf '%s' "$BOOTSTRAP_AGENTS" | jq -c '.[]' > "$work/agents"
while IFS= read -r agent; do
  name="$(printf '%s' "$agent" | jq -r .name)"
  description="$(printf '%s' "$agent" | jq -r .description)"
  ns="$(printf '%s' "$agent" | jq -r .namespace)"
  secret="$(printf '%s' "$agent" | jq -r .secretName)"

  # A key's secret is readable only when the key is created: keep an existing Secret.
  http GET "$k8s/api/v1/namespaces/$ns/secrets/$secret" "$work/k8s-auth"
  case "$STATUS" in
    200) log "secret $ns/$secret exists; skipping agent '$name'"; continue ;;
    404) ;;
    *) die "reading secret $ns/$secret returned $STATUS: $(cat "$work/body")" ;;
  esac

  http GET "$api/admin/agents" "$work/api-auth"
  [ "$STATUS" = 200 ] || die "GET /api/admin/agents returned $STATUS: $(cat "$work/body")"
  id="$(jq -r --arg n "$name" '[.data[]? | select(.name == $n)][0].id // empty' "$work/body")"
  if [ -z "$id" ]; then
    jq -n --arg n "$name" --arg d "$description" \
      '{name: $n, "is-active": true} + (if $d == "" then {} else {description: $d} end)' > "$work/agent.json"
    http POST "$api/admin/agents" "$work/api-auth" "$work/agent.json"
    case "$STATUS" in 200|201) ;; *) die "creating agent '$name' returned $STATUS: $(cat "$work/body")" ;; esac
    id="$(jq -r '.data.id // empty' "$work/body")"
    [ -n "$id" ] || die "creating agent '$name' returned no id"
    log "created agent '$name' ($id)"
  else
    log "found agent '$name' ($id)"
  fi

  jq -n --arg n "helm:$ns/$secret" '{name: $n, "never-expires": true}' > "$work/key.json"
  http POST "$api/admin/agents/$id/keys" "$work/api-auth" "$work/key.json"
  case "$STATUS" in 200|201) ;; *) die "creating a key for agent '$name' returned $STATUS: $(cat "$work/body")" ;; esac
  key_id="$(jq -r '.data.id // empty' "$work/body")"
  jq --arg ns "$ns" --arg name "$secret" --arg agent "$name" --arg agentId "$id" --arg release "$BOOTSTRAP_RELEASE" '{
      apiVersion: "v1", kind: "Secret", type: "Opaque",
      metadata: {
        name: $name, namespace: $ns,
        labels: {"app.kubernetes.io/managed-by": "ccf-agent-bootstrap", "app.kubernetes.io/part-of": "ccf"},
        annotations: {"compliance-framework.io/agent": $agent, "compliance-framework.io/agent-id": $agentId, "compliance-framework.io/created-by-release": $release}
      },
      stringData: {CCF_API_AUTH_CLIENT_ID: .data."client-id", CCF_API_AUTH_CLIENT_SECRET: .data."client-secret"}
    }' "$work/body" > "$work/secret.json"
  rm -f "$work/body"
  [ "$(jq -r '.stringData.CCF_API_AUTH_CLIENT_ID // empty' "$work/secret.json")" != "" ] || die "the key for agent '$name' came back without a client-id"

  http POST "$k8s/api/v1/namespaces/$ns/secrets" "$work/k8s-auth" "$work/secret.json"
  rm -f "$work/secret.json"
  if [ "$STATUS" != 201 ]; then
    log "creating secret $ns/$secret returned $STATUS: $(cat "$work/body")"
    if [ -n "$key_id" ]; then
      http DELETE "$api/admin/agents/$id/keys/$key_id" "$work/api-auth"
      log "revoked the unused key $key_id (status $STATUS)"
    fi
    exit 1
  fi
  log "stored a key for agent '$name' in secret $ns/$secret"
done < "$work/agents"

log "done"
{{- end }}
