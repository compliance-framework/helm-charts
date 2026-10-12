#!/usr/bin/env bash
# Argo CD compatibility check for both charts.
#
# 1. Renders each chart twice per values file the way Argo CD's repo-server does (helm template
#    without cluster access) and requires byte-identical output and no `lookup` call: a lookup
#    returns nothing there, and a random or generated value changes on every render.
# 2. Installs Argo CD on the current cluster (a kind cluster in CI), creates an Application per
#    chart and values set from REPO_URL at REVISION (existingSecret credentials, External Secrets
#    Operator credentials, and the agent chart) once both operators are ready (CRDs Established,
#    Deployments Available, ESO's webhook admitting a dry-run create), syncs them (a failed sync
#    is logged with its diagnostics and run again, SYNC_ATTEMPTS times in all), waits for
#    Synced + Healthy, checks the ESO path end to end (ExternalSecrets Ready, API ready with the
#    generated JWT key and Postgres password, Secret data unchanged after a forced sync), then
#    forces two hard refreshes and requires the Applications to stay Synced (no diff between
#    renders).
#
# Usage: REPO_URL=https://github.com/<owner>/<repo> REVISION=<sha> ci/argocd/check.sh [render|argocd|all]
set -euo pipefail

ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.4}"
ESO_VERSION="${ESO_VERSION:-2.11.0}"
# Every Application namespace enforces this Pod Security level; a rejected pod fails the check.
PSS_LEVEL="${PSS_LEVEL-restricted}"
TIMEOUT="${TIMEOUT:-900}"
# How long to wait for an operator (ESO, Argo CD) to be ready, and how many times a failed sync is
# run before the check fails (each failure is logged with its diagnostics, retried or not).
READY_TIMEOUT="${READY_TIMEOUT:-300}"
SYNC_ATTEMPTS="${SYNC_ATTEMPTS:-3}"
SYNC_BACKOFF="${SYNC_BACKOFF:-15}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
mode="${1:-all}"

log() { echo "argocd-check: $*" >&2; }

render_check() {
  local chart values out1 out2
  out1="$(mktemp)"; out2="$(mktemp)"
  for spec in \
      "charts/ccf-app:ci/argocd/ccf-app-values.yaml" \
      "charts/ccf-app:ci/argocd/ccf-app-eso-values.yaml" \
      "charts/ccf-app:ci/argocd/render/ccf-app-eso.yaml" \
      "charts/ccf-app:ci/argocd/render/ccf-app-dev.yaml" \
      "charts/ccf-agent:ci/argocd/ccf-agent-values.yaml"; do
    chart="${spec%%:*}"; values="${spec#*:}"
    for out in "$out1" "$out2"; do
      helm template ccf "$root/$chart" --namespace ccf -f "$root/$values" > "$out"
    done
    if ! cmp -s "$out1" "$out2"; then
      log "FAIL: $chart with $values renders differently each time:"
      diff "$out1" "$out2" | head -40 >&2
      exit 1
    fi
    log "ok: $chart with $values renders identically twice"
  done
  # lookup returns nothing under Argo CD, and render-time random values change on every render.
  # The only allowed uses are the DEPRECATED generated-credential helpers (the chart's pre-0.9.0
  # default, kept for compatibility, never used by these values sets) in
  # charts/ccf-app/templates/_deprecated_generated.tpl, each inside a ccf-app.deprecated.* define,
  # and the genPrivateKey string in externalsecrets.yaml, an ESO template literal Helm does not
  # evaluate.
  local hits f allowed="charts/ccf-app/templates/_deprecated_generated.tpl"
  hits="$(for f in "$root"/charts/*/templates/*.yaml "$root"/charts/*/templates/*.tpl "$root"/charts/*/templates/*/*.yaml; do
      [ -f "$f" ] || continue
      [ "${f#"$root"/}" = "$allowed" ] && continue
      # template comments ({{/* ... */}}) are not rendered
      perl -0pe 's/\{\{-?\s*\/\*.*?\*\/\s*-?\}\}//gs' "$f" \
        | grep -E '\blookup[[:space:]]+"|\b(genPrivateKey|genCA|genSelfSignedCert|genSignedCert|randAlphaNum|randAlpha|randNumeric|randAscii|randBytes|randInt|uuidv4|now)\b' \
        | sed "s|^|${f#"$root"/}: |"
    done \
    | grep -vE '^charts/ccf-app/templates/externalsecrets\.yaml: .*"\{\{ genPrivateKey' || true)"
  if [ -n "$hits" ]; then
    log "FAIL: lookup or render-time random values outside the deprecated generated helpers:"
    echo "$hits" >&2
    exit 1
  fi
  # Inside the allowed file, every such call must sit in a ccf-app.deprecated.* define.
  if ! perl -0ne '
      s/\{\{-?\s*\/\*.*?\*\/\s*-?\}\}//gs;
      my @blocks = split /(?=\{\{-?\s*define\s)/;
      for my $b (@blocks) {
        next unless $b =~ /\blookup\s+"|\b(genPrivateKey|rand[A-Za-z]+)\b/;
        exit 1 unless $b =~ /^\{\{-?\s*define\s+"ccf-app\.deprecated\./;
      }' "$root/$allowed"; then
    log "FAIL: lookup/random in $allowed outside a ccf-app.deprecated.* define"
    exit 1
  fi
  log "ok: lookup and random values only in the deprecated generated helpers"

  # The default values use those helpers: two default renders must differ only in their values.
  helm template ccf "$root/charts/ccf-app" --namespace ccf > "$out1"
  helm template ccf "$root/charts/ccf-app" --namespace ccf > "$out2"
  local unexpected
  unexpected="$(diff "$out1" "$out2" | grep -E '^[<>]' \
    | grep -vE '^[<>]   (private_key\.pem|POSTGRES_PASSWORD|password): ' || true)"
  if [ -n "$unexpected" ]; then
    log "FAIL: default renders differ outside the deprecated generated credentials:"
    echo "$unexpected" | head -20 >&2
    exit 1
  fi
  log "ok: default renders differ only in the deprecated generated credentials"
  rm -f "$out1" "$out2"
  if grep -rnE 'source:[[:space:]]*"?generated' "$root/ci/argocd"/*.yaml "$root/ci/argocd/render"/*.yaml; then
    log "FAIL: a values set of this check selects the deprecated api.jwt.source=generated, which is non-deterministic"
    exit 1
  fi
}

wait_until() { # wait_until <seconds> <description> <command...>
  local what="$2" deadline=$(( $(date +%s) + $1 )); shift 2
  until "$@"; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "FAIL: timed out waiting for $what"
      return 1
    fi
    sleep 5
  done
}

wait_for() { wait_until "$TIMEOUT" "$@"; } # wait_for <description> <command...>

default_project_exists() { kubectl -n argocd get appproject default >/dev/null 2>&1; }

app_get() { kubectl -n argocd get application "$1" -o jsonpath="$2" 2>/dev/null; }

app_state() { app_get "$1" '{.status.sync.status}/{.status.health.status}/{.status.operationState.phase}'; }

# start_sync NAME: requests a sync and waits until the controller has started it, so the
# operationState read afterwards is this sync's and not an earlier one's.
start_sync() {
  local before; before="$(app_get "$1" '{.status.operationState.startedAt}')"
  kubectl -n argocd patch application "$1" --type merge \
    -p "{\"operation\":{\"initiatedBy\":{\"username\":\"ci\"},\"sync\":{\"revision\":\"$REVISION\",\"prune\":true}}}" >/dev/null
  wait_until 120 "$1's sync to start" sync_started_after "$1" "$before"
}

sync_started_after() { # sync_started_after NAME STARTED_AT: an operation newer than STARTED_AT exists
  local now; now="$(app_get "$1" '{.status.operationState.startedAt}')"
  [ -n "$now" ] && [ "$now" != "$2" ]
}

# sync_done NAME: the sync failed, or it succeeded and the Application is Synced and Healthy.
sync_done() {
  case "$(app_state "$1")" in
    Synced/Healthy/Succeeded|*/*/Failed|*/*/Error) return 0 ;;
  esac
  return 1
}

# sync_app NAME: waits for the sync start_sync started; a failed sync is diagnosed and run again,
# with backoff, up to SYNC_ATTEMPTS times in all. A sync can fail on a transient state: with
# PostSync hooks (the bootstrap Job) Argo CD fails a sync task whose resource is Degraded while the
# sync runs, and an ExternalSecret is Degraded (Ready=False) until ESO sees its generator, which
# Argo CD may apply after it. A retried failure is still logged in full and annotated as a warning.
sync_app() {
  local name="$1" attempt=1 state
  while :; do
    wait_for "$name to be Synced and Healthy" sync_done_or_rejected "$name" || { diagnose "$name"; exit 1; }
    state="$(app_state "$name")"
    if [ "$state" = Synced/Healthy/Succeeded ]; then
      log "ok: $name is $state"
      return 0
    fi
    log "$name sync attempt $attempt/$SYNC_ATTEMPTS failed: $state"
    [ -z "${GITHUB_ACTIONS:-}" ] || echo "::warning::$name sync attempt $attempt/$SYNC_ATTEMPTS failed: $state (diagnostics in the log)"
    diagnose "$name"
    if [ "$attempt" -ge "$SYNC_ATTEMPTS" ]; then
      log "FAIL: $name sync failed $attempt times"
      exit 1
    fi
    sleep $(( SYNC_BACKOFF * attempt ))
    attempt=$(( attempt + 1 ))
    log "syncing $name again (attempt $attempt/$SYNC_ATTEMPTS)"
    start_sync "$name" || { diagnose "$name"; exit 1; }
  done
}

refresh_done() {
  [ -z "$(app_get "$1" '{.metadata.annotations.argocd\.argoproj\.io/refresh}')" ]
}

# diagnose NAME: every sync task with its result (failed ones marked), every resource that is not
# Synced and Healthy, the Application conditions, the logs of failed hook Jobs, recent events in
# the destination namespace and every pod. Printed in full: a failure must be diagnosable from the
# log alone.
diagnose() {
  local name="$1" json ns job
  json="$(kubectl -n argocd get application "$name" -o json 2>/dev/null)" || { log "cannot read Application $name"; return 0; }
  ns="$(jq -r '.spec.destination.namespace' <<<"$json")"
  {
    echo "--- $name: $(app_state "$name")"
    jq -r '
      def bad: ((.status // "") != "Synced") or ((.hookPhase // "") | test("Failed|Error"));
      "operation: \(.status.operationState.phase // "none"): \(.status.operationState.message // "")",
      "conditions:", ((.status.conditions // [])[] | "  \(.type): \(.message)"),
      "sync tasks (!! = not OK):",
      ((.status.operationState.syncResult.resources // [])[]
        | "  \(if bad then "!!" else "  " end) \(.syncPhase // "-") \(.hookType // "") \(.kind) \(.namespace // "")/\(.name): status=\(.status // "-") hookPhase=\(.hookPhase // "-") message=\(.message // "")"),
      "resources not Synced and Healthy:",
      ((.status.resources // [])[]
        | select(.status != "Synced" or ((.health.status // "Healthy") != "Healthy"))
        | "  \(.kind) \(.namespace // "")/\(.name): sync=\(.status // "-") health=\(.health.status // "-") \(.health.message // "")")
    ' <<<"$json"
    for job in $(jq -r '(.status.operationState.syncResult.resources // [])[]
        | select(.kind == "Job" and ((.hookPhase // "") | test("Failed|Error"))) | .name' <<<"$json"); do
      echo "logs of hook Job $ns/$job:"
      kubectl -n "$ns" logs "job/$job" --all-containers --tail=50 2>&1 | sed 's/^/  /'
    done
    echo "recent events in $ns:"
    kubectl -n "$ns" get events --sort-by=.lastTimestamp 2>&1 | tail -n 30 | sed 's/^/  /'
    echo "pods:"
    kubectl get pods -A 2>&1 | sed 's/^/  /'
  } >&2 || true
}

# Applications: name:chart path:values file:namespace
APPS="ccf:charts/ccf-app:ccf-app-values.yaml:ccf
ccf-eso:charts/ccf-app:ccf-app-eso-values.yaml:ccf-eso
ccf-agent:charts/ccf-agent:ccf-agent-values.yaml:ccf-agent"

app_names() { echo "$APPS" | cut -d: -f1; }

# make_namespace NAME: creates it with the Pod Security labels in $PSS_LEVEL (if any), so the
# API server rejects any pod that does not meet that profile.
make_namespace() {
  kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  if [ -n "${PSS_LEVEL:-}" ]; then
    kubectl label namespace "$1" --overwrite \
      "pod-security.kubernetes.io/enforce=$PSS_LEVEL" \
      "pod-security.kubernetes.io/warn=$PSS_LEVEL" \
      "pod-security.kubernetes.io/audit=$PSS_LEVEL" >/dev/null
  fi
}

# Fails as soon as the API server refuses a pod (e.g. Pod Security admission).
no_rejected_pods() {
  local rejected
  rejected="$(kubectl get events -A --field-selector reason=FailedCreate -o jsonpath='{range .items[*]}{.metadata.namespace}/{.involvedObject.name}: {.message}{"\n"}{end}' 2>/dev/null \
    | grep -i 'forbidden' || true)"
  if [ -n "$rejected" ]; then
    log "FAIL: pods were rejected:"
    echo "$rejected" >&2
    exit 1
  fi
}

secret_digest() { # secret_digest NAMESPACE NAME: a digest of the Secret's data, never the data
  kubectl -n "$1" get secret "$2" -o jsonpath='{.data}' | sha256sum | cut -c1-16
}

eso_check() {
  local ns=ccf-eso secrets="ccf-psql ccf-initial-user-password ccf-jwt-private-key" before after s
  log "checking the External Secrets Operator path"
  kubectl -n "$ns" wait externalsecret --all --for=condition=Ready --timeout=300s
  log "ok: every ExternalSecret is Ready"
  kubectl -n "$ns" rollout status deploy/ccf-api --timeout=300s
  # The API exits at start on a key it cannot parse and is not ready without the database, so a
  # ready API proves the genPrivateKey PEM works and Postgres took the generated password.
  log "ok: the API is ready with the ESO-generated JWT key and Postgres password"
  [ "$(kubectl -n "$ns" get secret ccf-jwt-private-key -o jsonpath='{.data.private_key\.pem}' | base64 -d | head -n 1)" \
    = "-----BEGIN RSA PRIVATE KEY-----" ] || { log "FAIL: the ESO JWT key is not a PKCS#1 PEM"; exit 1; }
  before=""; for s in $secrets; do before="$before $s=$(secret_digest "$ns" "$s")"; done
  kubectl -n "$ns" annotate externalsecret --all "force-sync=$(date +%s)" --overwrite >/dev/null
  sleep 30
  after=""; for s in $secrets; do after="$after $s=$(secret_digest "$ns" "$s")"; done
  if [ "$before" != "$after" ]; then
    log "FAIL: ESO changed Secret data after a forced sync (refreshPolicy CreatedOnce):$before ->$after"
    exit 1
  fi
  log "ok: Secret data unchanged after a forced ESO sync (CreatedOnce)"
  kubectl -n "$ns" get secret argocd-eso-agent-credentials >/dev/null \
    || { log "FAIL: the bootstrap Job did not create its Secret with the ESO-generated admin password"; exit 1; }
  log "ok: the bootstrap Job logged in with the ESO-generated initial user password"
}

# The ESO resources the ccf-eso Application creates (and the webhook probe below) need these.
ESO_CRDS="externalsecrets.external-secrets.io secretstores.external-secrets.io
passwords.generators.external-secrets.io"
ESO_WEBHOOK_CONFIGS="secretstore-validate externalsecret-validate"

webhook_ca_injected() { # webhook_ca_injected CONFIG: every webhook in it has a CA bundle
  kubectl get validatingwebhookconfiguration "$1" -o json 2>/dev/null \
    | jq -e '(.webhooks | length) > 0 and all(.webhooks[]; (.clientConfig.caBundle // "") != "")' >/dev/null
}

# eso_webhook_serves: a server-side dry-run create of a SecretStore and of an ExternalSecret shaped
# like the chart's goes through ESO's validating webhooks (failurePolicy Fail), so it succeeds only
# once the webhook serves with the injected CA. Nothing is persisted.
eso_probe_error=""
eso_webhook_serves() {
  if eso_probe_error="$(kubectl create --dry-run=server -o name -f - 2>&1 <<'EOF'
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: argocd-check-webhook-probe
  namespace: default
spec:
  provider:
    fake:
      data: []
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: argocd-check-webhook-probe
  namespace: default
spec:
  refreshPolicy: CreatedOnce
  target:
    name: argocd-check-webhook-probe
    creationPolicy: Owner
  dataFrom:
    - sourceRef:
        generatorRef:
          apiVersion: generators.external-secrets.io/v1alpha1
          kind: Password
          name: argocd-check-webhook-probe
EOF
)"; then
    return 0
  fi
  return 1
}

# eso_ready: the CRDs are Established, the controller, webhook and cert-controller are Available,
# the CA is injected into the validating webhooks and the webhook admits a dry-run create.
eso_ready() {
  local crd cfg
  for crd in $ESO_CRDS; do
    kubectl wait --for=condition=Established "crd/$crd" --timeout="${READY_TIMEOUT}s" >/dev/null
  done
  kubectl -n external-secrets wait --for=condition=Available --timeout="${READY_TIMEOUT}s" \
    deploy/external-secrets deploy/external-secrets-webhook deploy/external-secrets-cert-controller >/dev/null
  for cfg in $ESO_WEBHOOK_CONFIGS; do
    wait_until "$READY_TIMEOUT" "the CA in the $cfg webhook" webhook_ca_injected "$cfg" || exit 1
  done
  if ! wait_until "$READY_TIMEOUT" "the ESO webhook to admit a dry-run SecretStore and ExternalSecret" eso_webhook_serves; then
    log "last webhook probe error: $eso_probe_error"
    exit 1
  fi
  log "ok: External Secrets Operator is ready (CRDs Established, Deployments Available, webhook serving)"
}

# argocd_ready: the CRDs are Established, every Argo CD Deployment is Available, the application
# controller is rolled out and argocd-server has created the default AppProject.
argocd_ready() {
  kubectl wait --for=condition=Established --timeout="${READY_TIMEOUT}s" \
    crd/applications.argoproj.io crd/appprojects.argoproj.io >/dev/null
  kubectl -n argocd wait --for=condition=Available deploy --all --timeout=600s >/dev/null
  kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=600s
  # argocd-server creates the default AppProject on start; Applications fail without it.
  wait_for "the default AppProject" default_project_exists || exit 1
  log "ok: Argo CD is ready (CRDs Established, Deployments Available, default AppProject)"
}

argocd_check() {
  : "${REPO_URL:?set REPO_URL}" "${REVISION:?set REVISION}"
  log "installing External Secrets Operator $ESO_VERSION"
  helm upgrade --install external-secrets oci://ghcr.io/external-secrets/charts/external-secrets \
    --version "$ESO_VERSION" --namespace external-secrets --create-namespace --wait --timeout 10m >/dev/null

  log "installing Argo CD $ARGOCD_VERSION"
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argocd --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml" >/dev/null
  argocd_ready
  # Checked last, right before the ccf-eso Application creates ExternalSecrets.
  eso_ready

  log "creating the namespaces and the credentials the existingSecret values set references"
  local name path values ns
  while IFS=: read -r name path values ns; do make_namespace "$ns"; done <<<"$APPS"
  local key; key="$(mktemp)"
  openssl genrsa -out "$key" 2048 2>/dev/null
  kubectl -n ccf create secret generic ccf-jwt --from-file=private_key.pem="$key"
  kubectl -n ccf create secret generic ccf-admin --from-literal=password="$(openssl rand -hex 16)"
  kubectl -n ccf create secret generic ccf-postgres --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 16)"
  kubectl -n ccf create secret generic ccf-dex --from-literal=CCF_SSO_PROVIDERS_DEX_CLIENT_SECRET="$(openssl rand -hex 16)"
  rm -f "$key"

  while IFS=: read -r name path values ns; do
    kubectl apply -f - <<APP
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $name
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $REPO_URL
    targetRevision: $REVISION
    path: $path
    helm:
      releaseName: ccf
      valueFiles:
        - ../../ci/argocd/$values
  destination:
    server: https://kubernetes.default.svc
    namespace: $ns
APP
  done <<<"$APPS"

  for name in $(app_names); do
    log "syncing $name (attempt 1/$SYNC_ATTEMPTS)"
    start_sync "$name" || { diagnose "$name"; exit 1; }
  done
  for name in $(app_names); do sync_app "$name"; done
  no_rejected_pods

  eso_check

  for round in 1 2; do
    for name in $(app_names); do
      kubectl -n argocd annotate application "$name" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
    done
    for name in $(app_names); do
      wait_for "$name hard refresh $round" refresh_done "$name" || { diagnose "$name"; exit 1; }
      sync="$(kubectl -n argocd get application "$name" -o jsonpath='{.status.sync.status}')"
      drift="$(kubectl -n argocd get application "$name" \
        -o jsonpath='{range .status.resources[?(@.status!="Synced")]}{.kind}/{.name} {end}')"
      if [ "$sync" != Synced ] || [ -n "$drift" ]; then
        log "FAIL: $name is $sync after hard refresh $round; drifted: ${drift:-none}"
        diagnose "$name"
        exit 1
      fi
      log "ok: $name still Synced after hard refresh $round"
    done
  done
  no_rejected_pods
}

sync_done_or_rejected() { no_rejected_pods; sync_done "$1"; }

case "$mode" in
  render) render_check ;;
  argocd) argocd_check ;;
  all) render_check; argocd_check ;;
  *) echo "usage: $0 [render|argocd|all]" >&2; exit 2 ;;
esac
