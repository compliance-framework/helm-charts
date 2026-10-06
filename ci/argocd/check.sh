#!/usr/bin/env bash
# Argo CD compatibility check for both charts.
#
# 1. Renders each chart twice per values file the way Argo CD's repo-server does (helm template
#    without cluster access) and requires byte-identical output and no `lookup` call: a lookup
#    returns nothing there, and a random or generated value changes on every render.
# 2. Installs Argo CD on the current cluster (a kind cluster in CI), creates an Application per
#    chart from REPO_URL at REVISION, syncs it, waits for Synced + Healthy, then forces two hard
#    refreshes and requires the Applications to stay Synced (no diff between renders).
#
# Usage: REPO_URL=https://github.com/<owner>/<repo> REVISION=<sha> ci/argocd/check.sh [render|argocd|all]
set -euo pipefail

ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.4}"
TIMEOUT="${TIMEOUT:-900}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
mode="${1:-all}"

log() { echo "argocd-check: $*" >&2; }

render_check() {
  local chart values out1 out2
  out1="$(mktemp)"; out2="$(mktemp)"
  for spec in \
      "charts/ccf-app:ci/argocd/ccf-app-values.yaml" \
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

argocd_check() {
  : "${REPO_URL:?set REPO_URL}" "${REVISION:?set REVISION}"
  log "installing Argo CD $ARGOCD_VERSION"
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argocd --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml" >/dev/null
  kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=600s
  kubectl -n argocd rollout status deploy/argocd-redis --timeout=600s
  kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=600s

  log "creating the credentials the charts reference"
  for ns in ccf ccf-agent; do kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -; done
  local key; key="$(mktemp)"
  openssl genrsa -out "$key" 2048 2>/dev/null
  kubectl -n ccf create secret generic ccf-jwt --from-file=private_key.pem="$key"
  kubectl -n ccf create secret generic ccf-admin --from-literal=password="$(openssl rand -hex 16)"
  kubectl -n ccf create secret generic ccf-postgres --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 16)"
  rm -f "$key"

  for app in ccf:charts/ccf-app:ccf-app-values.yaml ccf-agent:charts/ccf-agent:ccf-agent-values.yaml; do
    IFS=: read -r name path values <<<"$app"
    local ns="$name"
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
  done

  for name in ccf ccf-agent; do
    log "syncing $name"
    kubectl -n argocd patch application "$name" --type merge \
      -p "{\"operation\":{\"initiatedBy\":{\"username\":\"ci\"},\"sync\":{\"revision\":\"$REVISION\",\"prune\":true}}}"
  done
  for name in ccf ccf-agent; do
    wait_for "$name to be Synced and Healthy" app_synced_healthy "$name" || { dump "$name"; exit 1; }
    log "ok: $name is $(app_state "$name")"
  done

  for round in 1 2; do
    for name in ccf ccf-agent; do
      kubectl -n argocd annotate application "$name" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
    done
    for name in ccf ccf-agent; do
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
}

case "$mode" in
  render) render_check ;;
  argocd) argocd_check ;;
  all) render_check; argocd_check ;;
  *) echo "usage: $0 [render|argocd|all]" >&2; exit 2 ;;
esac
