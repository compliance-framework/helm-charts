#!/usr/bin/env bash
# The checks use `cond && pass ... || fail ...`; pass always returns 0, so fail runs only when
# cond is false.
# shellcheck disable=SC2015
# Tests for charts/ccf-app/files/agent-bootstrap.sh: runs the script in the curl image the chart
# uses (as its non-root user, read-only root filesystem) against mock.py, a canned CCF API +
# Kubernetes Secrets API, and checks each scenario's outcome, requests and log.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
here="$root/ci/agent-bootstrap"
script="$root/charts/ccf-app/files/agent-bootstrap.sh"
curl_image="${CURL_IMAGE:-curlimages/curl:8.22.0}"
python_image="${PYTHON_IMAGE:-python:3.13.16-alpine}"
net="ccf-bootstrap-test-$$"
mock="ccf-bootstrap-mock-$$"
work="$(mktemp -d "${TMPDIR:-/tmp}/ccf-bootstrap-test.XXXXXX")"
failures=0

cleanup() {
  docker rm -f "$mock" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
docker network create "$net" >/dev/null

ADMIN_EMAIL="admin@example.com"
ADMIN_PASSWORD='s3cr3t "admin" \ pass'
API_TOKEN="eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJlLXNlY3JldA"
K8S_TOKEN="k8s-service-account-token-123"
AGENTS=$'0 ccf ccf-agent-credentials ccf-agent\n1 agents ccf-agent-2-credentials ccf agent 2.0'

fail() { echo "  FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "  ok: $*"; }

# run_scenario NAME SCENARIO_JSON: starts the mock, runs the script, leaves its exit code in
# $rc, its log in $state/job.log and the mock's request log in $state/requests.log.
run_scenario() {
  state="$work/$1"
  mkdir -p "$state/sa"
  chmod 0777 "$state"
  printf '%s' "$K8S_TOKEN" > "$state/sa/token"
  : > "$state/sa/ca.crt"
  : > "$state/requests.log"
  chmod 0666 "$state/requests.log"
  printf '%s' "$2" > "$state/scenario.json"
  docker rm -f "$mock" >/dev/null 2>&1 || true
  docker run -d --name "$mock" --network "$net" --network-alias mock \
    -v "$here/mock.py:/mock.py:ro" -v "$state:/state" "$python_image" python /mock.py >/dev/null
  for _ in $(seq 1 50); do
    docker exec "$mock" python -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8080/api/health/ready")' \
      >/dev/null 2>&1 && break
    sleep 0.2
  done
  : > "$state/requests.log"
  set +e
  docker run --rm --network "$net" --user 100:101 --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges \
    -v "$script:/agent-bootstrap.sh:ro" -v "$state/sa:/sa:ro" \
    -e BOOTSTRAP_API_URL=http://mock:8080/api -e BOOTSTRAP_KUBERNETES_URL=http://mock:8080 \
    -e BOOTSTRAP_SERVICEACCOUNT_DIR=/sa -e BOOTSTRAP_WAIT_SECONDS=10 -e BOOTSTRAP_RELEASE=ccf/ccf \
    -e BOOTSTRAP_AGENTS="$AGENTS" -e BOOTSTRAP_AGENT_0_DESCRIPTION='In-cluster "agent" \ test' \
    -e ADMIN_EMAIL="$ADMIN_EMAIL" -e ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    --entrypoint sh "$curl_image" /agent-bootstrap.sh > "$state/job.log" 2>&1
  rc=$?
  set -e
  sed 's/^/    | /' "$state/job.log"
}

requests() { grep -c "$1" "$state/requests.log" || true; }

no_secrets_in_log() {
  local leaked=""
  for value in "$ADMIN_PASSWORD" "$API_TOKEN" "$K8S_TOKEN"; do
    grep -qF -- "$value" "$state/job.log" && leaked="$leaked $value"
  done
  if [ -f "$state/keys.json" ]; then
    for value in $(python_secrets); do
      grep -qF -- "$value" "$state/job.log" && leaked="$leaked client-secret"
    done
  fi
  [ -z "$leaked" ] && pass "no password, token or client secret in the log" || fail "secrets in the log:$leaked"
}

python_secrets() {
  docker run --rm -v "$state:/state:ro" "$python_image" python -c \
    'import json; print("\n".join(k["client-secret"] for k in json.load(open("/state/keys.json")).values()))'
}

base='"admin_email":"'"$ADMIN_EMAIL"'","admin_password":"s3cr3t \"admin\" \\ pass","api_token":"'"$API_TOKEN"'","k8s_token":"'"$K8S_TOKEN"'"'

echo "scenario: every Secret exists"
run_scenario all-exist "{$base,\"secrets\":[\"ccf/ccf-agent-credentials\",\"agents/ccf-agent-2-credentials\"]}"
[ "$rc" = 0 ] && pass "exit 0" || fail "exit $rc"
[ "$(requests '/api/auth/login')" = 0 ] && pass "no login" || fail "logged in"
[ "$(requests '/api/health/ready')" = 0 ] && pass "no API call" || fail "waited for the API"
grep -q "all 2 Secrets exist; nothing to do" "$state/job.log" && pass "logged nothing to do" || fail "no 'nothing to do' log"
no_secrets_in_log

echo "scenario: create a new agent"
run_scenario create-new "{$base,\"secrets\":[\"ccf/ccf-agent-credentials\"],\"agents\":[{\"id\":\"11111111-1111-4111-8111-111111111111\",\"name\":\"ccf agent 2.0-old\"}]}"
[ "$rc" = 0 ] && pass "exit 0" || fail "exit $rc"
[ "$(requests '"POST","path":"/api/admin/agents"')" = 1 ] && pass "created one agent" || fail "agent creations: $(requests '"POST","path":"/api/admin/agents"')"
grep -q '"POST","path":"/api/admin/agents","body":"{\\"name\\":\\"ccf agent 2.0\\",\\"is-active\\":true}"' "$state/requests.log" \
  && pass "agent body (no description for agent 1)" || fail "unexpected agent body"
docker run --rm -v "$state:/state:ro" "$python_image" python -c '
import base64, json, sys
secrets = json.load(open("/state/secrets.json"))
keys = list(json.load(open("/state/keys.json")).values())
s = secrets["agents/ccf-agent-2-credentials"]
cid = base64.b64decode(s["data"]["CCF_API_AUTH_CLIENT_ID"]).decode()
csec = base64.b64decode(s["data"]["CCF_API_AUTH_CLIENT_SECRET"]).decode()
assert (cid, csec) == (keys[0]["client-id"], keys[0]["client-secret"]), "Secret data != created key"
assert s["metadata"]["annotations"]["compliance-framework.io/agent"] == "ccf agent 2.0"
assert keys[0]["name"] == "helm:agents/ccf-agent-2-credentials"
' && pass "Secret holds the new key (base64 data) and annotations" || fail "Secret content"
no_secrets_in_log

echo "scenario: an existing agent is found by exact name"
run_scenario existing "{$base,\"agents\":[{\"id\":\"22222222-2222-4222-8222-222222222222\",\"name\":\"ccf-agent-2\"},{\"id\":\"33333333-3333-4333-8333-333333333333\",\"name\":\"ccf-agent\",\"description\":\"has \\\"quotes\\\", \\\"name\\\":\\\"ccf agent 2.0\\\"\"},{\"id\":\"44444444-4444-4444-8444-444444444444\",\"name\":\"ccf agent 2.0\"}]}"
[ "$rc" = 0 ] && pass "exit 0" || fail "exit $rc"
[ "$(requests '"POST","path":"/api/admin/agents"')" = 0 ] && pass "created no agent" || fail "created an agent"
[ "$(requests '/api/admin/agents/33333333-3333-4333-8333-333333333333/keys')" = 1 ] && pass "key for ccf-agent (not ccf-agent-2)" || fail "wrong agent for ccf-agent"
[ "$(requests '/api/admin/agents/44444444-4444-4444-8444-444444444444/keys')" = 1 ] && pass "key for 'ccf agent 2.0' (a description mentioning the name is not a match)" || fail "wrong agent for 'ccf agent 2.0'"
no_secrets_in_log

echo "scenario: duplicate agent names fail"
run_scenario duplicate "{$base,\"secrets\":[\"agents/ccf-agent-2-credentials\"],\"agents\":[{\"id\":\"55555555-5555-4555-8555-555555555555\",\"name\":\"ccf-agent\"},{\"id\":\"66666666-6666-4666-8666-666666666666\",\"name\":\"ccf-agent\"}]}"
[ "$rc" != 0 ] && pass "exit $rc" || fail "exit 0"
grep -q "2 agents are named 'ccf-agent'.*rename or remove the duplicates" "$state/job.log" && pass "clear duplicate message" || fail "no duplicate message"
[ "$(requests '/keys')" = 0 ] && pass "created no key" || fail "created a key"
no_secrets_in_log

echo "scenario: a failed Secret create revokes the key"
run_scenario revoke "{$base,\"secrets\":[\"agents/ccf-agent-2-credentials\"],\"secret_create_status\":403,\"agents\":[{\"id\":\"77777777-7777-4777-8777-777777777777\",\"name\":\"ccf-agent\"}]}"
[ "$rc" != 0 ] && pass "exit $rc" || fail "exit 0"
[ "$(requests '"DELETE","path":"/api/admin/agents/77777777-7777-4777-8777-777777777777/keys/')" = 1 ] && pass "revoked the key" || fail "key not revoked"
no_secrets_in_log

echo "scenario: wrong admin password"
ADMIN_PASSWORD_SAVED="$ADMIN_PASSWORD"; ADMIN_PASSWORD="wrong-password"
run_scenario bad-login "{$base,\"secrets\":[\"ccf/ccf-agent-credentials\"]}"
ADMIN_PASSWORD="$ADMIN_PASSWORD_SAVED"
[ "$rc" != 0 ] && pass "exit $rc" || fail "exit 0"
grep -qF "wrong-password" "$state/job.log" && fail "password in the log" || pass "password not in the log"

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
