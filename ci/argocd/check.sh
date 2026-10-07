#!/usr/bin/env bash
# Argo CD compatibility check for both charts.
#
# 1. Renders each chart twice per values file the way Argo CD's repo-server does (helm template
#    without cluster access) and requires byte-identical output and no `lookup` call: a lookup
#    returns nothing there, and a random or generated value changes on every render.
# 2. Installs Argo CD on the current cluster (a kind cluster in CI), creates an Application per
#    chart and values set from REPO_URL at REVISION (existingSecret credentials, External Secrets
#    Operator credentials, and the agent chart), syncs them, waits for Synced + Healthy, checks
#    the ESO path end to end (ExternalSecrets Ready, API ready with the generated JWT key and
#    Postgres password, Secret data unchanged after a forced sync), then forces two hard
#    refreshes and requires the Applications to stay Synced (no diff between renders).
#
# Usage: REPO_URL=https://github.com/<owner>/<repo> REVISION=<sha> ci/argocd/check.sh [render|argocd|all]
set -euo pipefail

ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.4}"
ESO_VERSION="${ESO_VERSION:-2.11.0}"
TIMEOUT="${TIMEOUT:-900}"
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
  if grep -rnE '\blookup[[:space:]]+"' "$root/charts" --include='*.yaml' --include='*.tpl'; then
    log "FAIL: the charts call lookup, which returns nothing under Argo CD"
    exit 1
  fi
  log "ok: no lookup in the charts"
  # Render-time random or generated values change on every Argo CD render. The only allowed uses:
  # - the DEPRECATED api.jwt.source=generated branch in secrets_api.yaml (explicit opt-in, never in
  #   these values sets: it is non-deterministic by design);
  # - the genPrivateKey string in externalsecrets.yaml, an ESO template literal that Helm does not
  #   evaluate.
  local hits f
  hits="$(for f in "$root"/charts/*/templates/*.yaml "$root"/charts/*/templates/*.tpl "$root"/charts/*/templates/*/*.yaml; do
      [ -f "$f" ] || continue
      # template comments ({{/* ... */}}) are not rendered
      perl -0pe 's/\{\{-?\s*\/\*.*?\*\/\s*-?\}\}//gs' "$f" \
        | grep -E '\b(genPrivateKey|genCA|genSelfSignedCert|genSignedCert|randAlphaNum|randAlpha|randNumeric|randAscii|randBytes|randInt|uuidv4|now)\b' \
        | sed "s|^|${f#"$root"/}: |"
    done \
    | grep -vE '^charts/ccf-app/templates/externalsecrets\.yaml: .*"\{\{ genPrivateKey' \
    | grep -vE '^charts/ccf-app/templates/secrets_api\.yaml:   private_key\.pem: \{\{ genPrivateKey "rsa" \| b64enc \}\}$' || true)"
  if [ -n "$hits" ]; then
    log "FAIL: render-time random or generated values outside the allowed deprecated path:"
    echo "$hits" >&2
    exit 1
  fi
  if ! awk '/if and .Values.api.enabled \(eq \(toString .Values.api.jwt.source\) "generated"\)/{g=1} g && /genPrivateKey/{found=1} /\{\{- end \}\}/{g=0} END{exit !found}' \
      "$root/charts/ccf-app/templates/secrets_api.yaml"; then
    log "FAIL: genPrivateKey in secrets_api.yaml must stay inside the api.jwt.source=generated branch"
    exit 1
  fi
  log "ok: no render-time random values except the deprecated, explicitly selected api.jwt.source=generated"
  if grep -rnE 'source:[[:space:]]*"?generated' "$root/ci/argocd"/*.yaml "$root/ci/argocd/render"/*.yaml; then
    log "FAIL: a values set of this check selects api.jwt.source=generated, which is non-deterministic by design"
    exit 1
  fi
  rm -f "$out1" "$out2"
}

wait_for() { # wait_for <description> <command...>
  local what="$1" deadline=$(( $(date +%s) + TIMEOUT )); shift
  until "$@"; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "FAIL: timed out waiting for $what"
      return 1
    fi
    sleep 5
  done
}

default_project_exists() { kubectl -n argocd get appproject default >/dev/null 2>&1; }

app_state() {
  kubectl -n argocd get application "$1" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}/{.status.operationState.phase}' 2>/dev/null
}

app_synced_healthy() {
  local state; state="$(app_state "$1")"
  case "$state" in
    Synced/Healthy/Succeeded) return 0 ;;
    */*/Failed|*/*/Error) log "FAIL: $1 sync failed: $state"; dump "$1"; exit 1 ;;
  esac
  return 1
}

refresh_done() {
  [ -z "$(kubectl -n argocd get application "$1" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/refresh}')" ]
}

dump() {
  kubectl -n argocd get application "$1" -o yaml | sed -n '/^status:/,$p' | head -120 >&2 || true
  kubectl get pods -A >&2 || true
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
  kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=600s
  kubectl -n argocd rollout status deploy/argocd-redis --timeout=600s
  kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=600s
  kubectl -n argocd rollout status deploy/argocd-server --timeout=600s
  # argocd-server creates the default AppProject on start; Applications fail without it.
  wait_for "the default AppProject" default_project_exists || exit 1

  log "creating the namespaces and the credentials the existingSecret values set references"
  local name path values ns
  while IFS=: read -r name path values ns; do make_namespace "$ns"; done <<<"$APPS"
  local key; key="$(mktemp)"
  openssl genrsa -out "$key" 2048 2>/dev/null
  kubectl -n ccf create secret generic ccf-jwt --from-file=private_key.pem="$key"
  kubectl -n ccf create secret generic ccf-admin --from-literal=password="$(openssl rand -hex 16)"
  kubectl -n ccf create secret generic ccf-postgres --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 16)"
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
    log "syncing $name"
    kubectl -n argocd patch application "$name" --type merge \
      -p "{\"operation\":{\"initiatedBy\":{\"username\":\"ci\"},\"sync\":{\"revision\":\"$REVISION\",\"prune\":true}}}"
  done
  for name in $(app_names); do
    wait_for "$name to be Synced and Healthy" app_synced_healthy_or_rejected "$name" || { dump "$name"; exit 1; }
    log "ok: $name is $(app_state "$name")"
  done
  no_rejected_pods

  eso_check

  for round in 1 2; do
    for name in $(app_names); do
      kubectl -n argocd annotate application "$name" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
    done
    for name in $(app_names); do
      wait_for "$name hard refresh $round" refresh_done "$name" || { dump "$name"; exit 1; }
      sync="$(kubectl -n argocd get application "$name" -o jsonpath='{.status.sync.status}')"
      drift="$(kubectl -n argocd get application "$name" \
        -o jsonpath='{range .status.resources[?(@.status!="Synced")]}{.kind}/{.name} {end}')"
      if [ "$sync" != Synced ] || [ -n "$drift" ]; then
        log "FAIL: $name is $sync after hard refresh $round; drifted: ${drift:-none}"
        dump "$name"
        exit 1
      fi
      log "ok: $name still Synced after hard refresh $round"
    done
  done
  no_rejected_pods
}

app_synced_healthy_or_rejected() { no_rejected_pods; app_synced_healthy "$1"; }

case "$mode" in
  render) render_check ;;
  argocd) argocd_check ;;
  all) render_check; argocd_check ;;
  *) echo "usage: $0 [render|argocd|all]" >&2; exit 2 ;;
esac
