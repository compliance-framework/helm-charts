#!/bin/sh
# Agent bootstrap Job script (charts/ccf-app, api.agentBootstrap).
#
# POSIX sh using only curl (>= 8.3, for --variable/--expand-data) and the
# busybox tools of the curlimages/curl image: no jq, nothing installed at runtime.
#
# Secrets never reach argv or the log:
# - request bodies are curl --expand-data templates that reference variables; curl reads the values
#   from the environment (--variable %NAME) or from files (--variable NAME@file) and encodes them
#   itself ({{NAME:json}} for JSON strings, {{NAME:b64}} for Secret data);
# - Authorization headers come from files (-H @file);
# - only non-2xx response bodies (error messages) are logged.
#
# Responses are read without a JSON parser, relying on these api v0.21.0 facts:
# - echo serializes with encoding/json: no indentation unless ?pretty is passed, and every '"'
#   inside a string value is escaped as \", so a key pattern such as "id": can only match a real
#   key, never text inside a value;
# - data.auth_token is an RS256 JWT ([A-Za-z0-9_.-]); ids and client-ids are lowercase UUIDs
#   (uuid.UUID / uuid.NewString); client-secret is base64.RawURLEncoding of 32 random bytes
#   ([A-Za-z0-9_-], 43 characters);
# - GET /api/admin/agents returns agentResponse objects whose fields come in struct order: id,
#   created-at, updated-at, name. Agent names are restricted (see agentBootstrap.agents) to
#   characters encoding/json writes unescaped, so the name matches its JSON form literally.
# The API has no name filter on GET /api/admin/agents and does not reject duplicate names on
# POST, so the list lookup is what keeps the Job from creating a second agent with the same name.
#
# Inputs (env): BOOTSTRAP_API_URL, BOOTSTRAP_WAIT_SECONDS, BOOTSTRAP_RELEASE, BOOTSTRAP_AGENTS
# ("<index> <namespace> <secretName> <name>" per line), BOOTSTRAP_AGENT_<index>_DESCRIPTION,
# ADMIN_EMAIL, ADMIN_PASSWORD (only needed when a Secret is missing). For tests:
# BOOTSTRAP_KUBERNETES_URL and BOOTSTRAP_SERVICEACCOUNT_DIR.
#
# Flow: check every Secret first and exit 0 when none is missing (no API call, no login); else
# wait for the API, log in, and for each missing Secret find the agent by exact name (fail when
# several agents share it) or create it, create a key, and store it in the Secret (revoking the
# key if the Secret cannot be created).
set -eu

log() { echo "agent-bootstrap: $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

command -v curl >/dev/null 2>&1 || die "the image needs curl"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
umask 077

api="${BOOTSTRAP_API_URL%/}"
# Overridable for the script's tests (ci/agent-bootstrap); the defaults are the in-cluster ones.
sa="${BOOTSTRAP_SERVICEACCOUNT_DIR:-/var/run/secrets/kubernetes.io/serviceaccount}"
k8s="${BOOTSTRAP_KUBERNETES_URL:-https://kubernetes.default.svc}"
s='[[:space:]]*'
printf 'Authorization: Bearer %s\n' "$(cat "$sa/token")" > "$work/k8s-auth"
: > "$work/no-auth"

# http METHOD URL AUTHFILE [curl args...]: sets STATUS and writes the response body to
# $work/body. The Kubernetes API is verified with the service account CA.
http() {
  method="$1"; url="$2"; auth="$3"; shift 3
  case "$url" in
    "$k8s"/*) set -- --cacert "$sa/ca.crt" "$@" ;;
  esac
  STATUS="$(curl -q -sS -o "$work/body" -w '%{http_code}' -X "$method" -H "@$auth" \
    -H 'Content-Type: application/json' "$@" "$url")" || STATUS=000
}

# field KEY CHARS: the first string value of "KEY" in $work/body made only of CHARS.
field() {
  tr -d '\r\n' < "$work/body" | grep -o "\"$1\"$s:$s\"[$2]*\"" | head -n 1 \
    | sed "s/^\"$1\"$s:$s\"\\([$2]*\\)\"\$/\\1/"
}

uuid_chars='0-9a-f-'

# 1. Which Secrets are missing? A key's secret is readable only when the key is created, so an
# existing Secret is kept and its agent skipped. When none is missing the Job is done: it never
# needs the API or the admin password on a no-op upgrade.
printf '%s\n' "$BOOTSTRAP_AGENTS" > "$work/agents"
: > "$work/missing"
total=0
while read -r index ns secret name; do
  [ -n "$index" ] || continue
  total=$((total + 1))
  http GET "$k8s/api/v1/namespaces/$ns/secrets/$secret" "$work/k8s-auth"
  case "$STATUS" in
    200) log "secret $ns/$secret exists; skipping agent '$name'" ;;
    404) printf '%s %s %s %s\n' "$index" "$ns" "$secret" "$name" >> "$work/missing" ;;
    *) die "reading secret $ns/$secret returned $STATUS: $(cat "$work/body")" ;;
  esac
done < "$work/agents"
if [ ! -s "$work/missing" ]; then
  log "all $total Secrets exist; nothing to do"
  exit 0
fi

# 2. Wait for the API to be ready.
deadline=$(( $(date +%s) + ${BOOTSTRAP_WAIT_SECONDS:-300} ))
log "waiting for $api/health/ready"
until curl -q -fsS -o /dev/null "$api/health/ready" 2>/dev/null; do
  [ "$(date +%s)" -lt "$deadline" ] || die "the API was not ready within ${BOOTSTRAP_WAIT_SECONDS:-300}s"
  sleep 5
done

# 3. Log in as the admin user.
[ -n "${ADMIN_PASSWORD:-}" ] || die "no admin password (its Secret or key is missing): set api.agentBootstrap.adminCredentials, or check the initial user's password source"
http POST "$api/auth/login" "$work/no-auth" --variable '%ADMIN_EMAIL' --variable '%ADMIN_PASSWORD' \
  --expand-data '{"email":"{{ADMIN_EMAIL:json}}","password":"{{ADMIN_PASSWORD:json}}"}'
[ "$STATUS" = 200 ] || die "POST /api/auth/login as $ADMIN_EMAIL returned $STATUS"
token="$(field auth_token 'A-Za-z0-9_.-')"
[ -n "$token" ] || die "POST /api/auth/login returned no token"
printf 'Authorization: Bearer %s\n' "$token" > "$work/api-auth"
unset token
rm -f "$work/body"

# 4. For each missing Secret: find or create the agent, create a key, store it.
while read -r index ns secret name; do
  [ -n "$index" ] || continue

  http GET "$api/admin/agents" "$work/api-auth"
  [ "$STATUS" = 200 ] || die "GET /api/admin/agents returned $STATUS: $(cat "$work/body")"
  name_re="$(printf '%s' "$name" | sed 's/[.]/[.]/g')"
  tr -d '\r\n' < "$work/body" \
    | grep -o "\"id\"$s:$s\"[$uuid_chars]*\"$s,$s\"created-at\"$s:$s\"[^\"]*\"$s,$s\"updated-at\"$s:$s\"[^\"]*\"$s,$s\"name\"$s:$s\"$name_re\"" \
    | sed "s/^\"id\"$s:$s\"\\([$uuid_chars]*\\)\".*/\\1/" > "$work/ids" || true
  matches="$(grep -c . "$work/ids" || true)"
  if [ "$matches" -gt 1 ]; then
    die "$matches agents are named '$name' ($(tr '\n' ' ' < "$work/ids")); rename or remove the duplicates in Admin -> Agents, then re-run"
  fi
  id="$(head -n 1 "$work/ids")"
  if [ -z "$id" ]; then
    description_var="BOOTSTRAP_AGENT_${index}_DESCRIPTION"
    if [ -n "$(printenv "$description_var" || true)" ]; then
      http POST "$api/admin/agents" "$work/api-auth" --variable "%$description_var" \
        --expand-data "{\"name\":\"$name\",\"is-active\":true,\"description\":\"{{$description_var:json}}\"}"
    else
      http POST "$api/admin/agents" "$work/api-auth" --data-binary "{\"name\":\"$name\",\"is-active\":true}"
    fi
    case "$STATUS" in 200|201) ;; *) die "creating agent '$name' returned $STATUS: $(cat "$work/body")" ;; esac
    id="$(field id "$uuid_chars")"
    [ -n "$id" ] || die "creating agent '$name' returned no id"
    log "created agent '$name' ($id)"
  else
    log "found agent '$name' ($id)"
  fi

  http POST "$api/admin/agents/$id/keys" "$work/api-auth" \
    --data-binary "{\"name\":\"helm:$ns/$secret\",\"never-expires\":true}"
  case "$STATUS" in 200|201) ;; *) die "creating a key for agent '$name' returned $STATUS: $(cat "$work/body")" ;; esac
  key_id="$(field id "$uuid_chars")"
  printf '%s' "$(field client-id "$uuid_chars")" > "$work/client-id"
  printf '%s' "$(field client-secret 'A-Za-z0-9_-')" > "$work/client-secret"
  rm -f "$work/body"
  [ -s "$work/client-id" ] && [ -s "$work/client-secret" ] \
    || die "the key for agent '$name' came back without a client-id or client-secret"

  http POST "$k8s/api/v1/namespaces/$ns/secrets" "$work/k8s-auth" \
    --variable "CLIENT_ID@$work/client-id" --variable "CLIENT_SECRET@$work/client-secret" \
    --expand-data "{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"type\":\"Opaque\",\"metadata\":{\"name\":\"$secret\",\"namespace\":\"$ns\",\"labels\":{\"app.kubernetes.io/managed-by\":\"ccf-agent-bootstrap\",\"app.kubernetes.io/part-of\":\"ccf\"},\"annotations\":{\"compliance-framework.io/agent\":\"$name\",\"compliance-framework.io/agent-id\":\"$id\",\"compliance-framework.io/created-by-release\":\"$BOOTSTRAP_RELEASE\"}},\"data\":{\"CCF_API_AUTH_CLIENT_ID\":\"{{CLIENT_ID:b64}}\",\"CCF_API_AUTH_CLIENT_SECRET\":\"{{CLIENT_SECRET:b64}}\"}}"
  rm -f "$work/client-id" "$work/client-secret"
  if [ "$STATUS" != 201 ]; then
    log "creating secret $ns/$secret returned $STATUS: $(cat "$work/body")"
    if [ -n "$key_id" ]; then
      http DELETE "$api/admin/agents/$id/keys/$key_id" "$work/api-auth"
      log "revoked the unused key $key_id (status $STATUS)"
    fi
    exit 1
  fi
  log "stored a key for agent '$name' in secret $ns/$secret"
done < "$work/missing"

log "done"
