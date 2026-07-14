#!/usr/bin/env bash
# Scripted install of Model Builder + claude-subscription-gateway on Kubernetes.
# Idempotent: safe to re-run; existing secrets and the Claude login are never
# overwritten.
#
# This file is self-contained: run it next to a deploy/k8s directory (a clone
# of transpara/model-builder or transpara/model-builder-install) and it uses
# those manifests; run it standalone and it fetches them from the public
# transpara/model-builder-install repo.
#
# Usage:
#   GITHUB_USER=<you> GITHUB_TOKEN=<classic PAT with read:packages> ./install-model-builder.sh
#
# Anything missing is prompted for. Flags:
#   --install-k3s   install k3s first if there is no working kubectl (for a
#                   box that does not have Kubernetes yet)
#   --skip-login    do not offer the interactive `claude setup-token` step
set -euo pipefail

NS=model-builder
GATEWAY_URL_IN_CLUSTER="http://claude-subscription-gateway:8790"
MANIFEST_TARBALL="https://github.com/transpara/model-builder-install/archive/refs/heads/main.tar.gz"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_K3S=false
SKIP_LOGIN=false
for arg in "$@"; do
  case "$arg" in
    --install-k3s) INSTALL_K3S=true ;;
    --skip-login)  SKIP_LOGIN=true ;;
    *) echo "Unknown flag: $arg (supported: --install-k3s, --skip-login)" >&2; exit 1 ;;
  esac
done

say()  { echo; echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

GITHUB_USER="${GITHUB_USER:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
ensure_github_user() {
  if [ -z "$GITHUB_USER" ]; then
    [ -t 0 ] || die "GITHUB_USER not set and no TTY to prompt"
    read -rp "GitHub username: " GITHUB_USER
  fi
}
ensure_github_token() {
  if [ -z "$GITHUB_TOKEN" ]; then
    [ -t 0 ] || die "GITHUB_TOKEN not set and no TTY to prompt"
    read -rsp "GitHub classic PAT (read:packages): " GITHUB_TOKEN; echo
  fi
}

# Manifests: prefer a deploy/k8s next to (or one level above) the script;
# otherwise fetch the public install repo tarball. No credentials needed.
REPO_ROOT=""
for cand in "$SCRIPT_DIR/.." "$SCRIPT_DIR"; do
  if [ -d "$cand/deploy/k8s" ]; then REPO_ROOT="$(cd "$cand" && pwd)"; break; fi
done
if [ -z "$REPO_ROOT" ]; then
  say "No local deploy/k8s next to the script; fetching manifests"
  TMP_SRC="$(mktemp -d)"
  trap 'rm -rf "$TMP_SRC"' EXIT
  curl -fsSL "$MANIFEST_TARBALL" | tar xz -C "$TMP_SRC" --strip-components=1
  [ -d "$TMP_SRC/deploy/k8s" ] || die "failed to fetch manifests from $MANIFEST_TARBALL"
  REPO_ROOT="$TMP_SRC"
fi

# ── kubectl / cluster access ─────────────────────────────────────────────
say "Checking cluster access"
KUBECTL=""
if command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then
  KUBECTL="kubectl"
elif sudo -n true 2>/dev/null && sudo kubectl get nodes >/dev/null 2>&1; then
  # k3s installs kubectl with a root-owned kubeconfig
  KUBECTL="sudo kubectl"
elif command -v kubectl >/dev/null 2>&1 && sudo kubectl get nodes >/dev/null 2>&1; then
  KUBECTL="sudo kubectl"
fi

if [ -z "$KUBECTL" ]; then
  if [ "$INSTALL_K3S" = true ]; then
    say "No working kubectl; installing k3s"
    curl -sfL https://get.k3s.io | sudo sh -
    KUBECTL="sudo kubectl"
  else
    die "no working kubectl. If this box has no Kubernetes, re-run with --install-k3s"
  fi
fi

$KUBECTL wait --for=condition=Ready node --all --timeout=120s >/dev/null
echo "Cluster reachable: $($KUBECTL get nodes --no-headers | wc -l) node(s) Ready (using: $KUBECTL)"

if ! $KUBECTL get storageclass 2>/dev/null | grep -q '(default)'; then
  warn "no default StorageClass; PVCs will stay Pending. k3s ships one; on other clusters install a provisioner first."
fi

# ── namespace + secrets ──────────────────────────────────────────────────
say "Namespace and secrets"
$KUBECTL get namespace "$NS" >/dev/null 2>&1 || $KUBECTL create namespace "$NS"

if $KUBECTL -n "$NS" get secret ghcr-pull >/dev/null 2>&1; then
  echo "ghcr-pull secret exists, keeping it"
else
  ensure_github_user
  ensure_github_token
  $KUBECTL -n "$NS" create secret docker-registry ghcr-pull \
    --docker-server=ghcr.io \
    --docker-username="$GITHUB_USER" \
    --docker-password="$GITHUB_TOKEN"
fi

if $KUBECTL -n "$NS" get secret gateway-secrets >/dev/null 2>&1; then
  echo "gateway-secrets exists, keeping it (existing CSG_API_KEY stays valid)"
else
  $KUBECTL -n "$NS" create secret generic gateway-secrets \
    --from-literal=CSG_API_KEY="$(openssl rand -hex 32)" \
    --from-literal=CSG_ADMIN_PASSWORD="$(openssl rand -hex 12)"
fi
CSG_API_KEY=$($KUBECTL -n "$NS" get secret gateway-secrets -o jsonpath='{.data.CSG_API_KEY}' | base64 -d)

# ── deploy ───────────────────────────────────────────────────────────────
say "Applying manifests"
$KUBECTL apply -k "$REPO_ROOT/deploy/k8s/"

say "Waiting for rollouts (first image pulls can take a few minutes)"
$KUBECTL -n "$NS" rollout status deploy/claude-subscription-gateway --timeout=300s
$KUBECTL -n "$NS" rollout status deploy/model-builder --timeout=300s

say "Health checks"
$KUBECTL -n "$NS" exec deploy/claude-subscription-gateway -- curl -sf http://localhost:8790/healthz >/dev/null \
  && echo "gateway /healthz ok" || die "gateway /healthz failed"
$KUBECTL -n "$NS" exec deploy/claude-subscription-gateway -- curl -sf http://localhost:8790/readyz >/dev/null \
  && echo "gateway /readyz ok" || die "gateway /readyz failed"
$KUBECTL -n "$NS" exec deploy/model-builder -- python -c \
  "import urllib.request; urllib.request.urlopen('http://localhost:4010/health', timeout=10)" \
  && echo "model-builder /health ok" || die "model-builder /health failed"

# ── Claude subscription login ────────────────────────────────────────────
probe_login() {
  $KUBECTL -n "$NS" exec deploy/claude-subscription-gateway -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 120 \
    -X POST http://localhost:8790/v1/messages \
    -H "x-api-key: $CSG_API_KEY" -H 'content-type: application/json' \
    -d '{"model":"sonnet","max_tokens":8,"messages":[{"role":"user","content":"Reply with exactly: ok"}]}' \
    2>/dev/null || echo 000
}

say "Checking Claude subscription login"
LOGGED_IN=false
CODE=$(probe_login)
if [ "$CODE" = "200" ]; then
  echo "Subscription login present and working"
  LOGGED_IN=true
elif [ "$SKIP_LOGIN" = true ] || [ ! -t 0 ]; then
  warn "gateway not logged in (probe returned $CODE); skipping interactive login"
else
  echo "The gateway has no working Claude login yet (probe returned $CODE)."
  read -rp "Run 'claude setup-token' in the gateway pod now? [y/N] " yn
  if [ "${yn,,}" = "y" ]; then
    $KUBECTL -n "$NS" exec -it deploy/claude-subscription-gateway -- claude setup-token || true
    CODE=$(probe_login)
    if [ "$CODE" = "200" ]; then
      echo "Login verified end to end"
      LOGGED_IN=true
    else
      warn "probe still returns $CODE; see the install guide, step 5"
    fi
  fi
fi

# ── wire Model Builder to the gateway (settings API) ─────────────────────
say "Configuring Model Builder's gateway settings"
$KUBECTL -n "$NS" exec deploy/model-builder -- \
  env MB_KEY="$CSG_API_KEY" MB_URL="$GATEWAY_URL_IN_CLUSTER" python -c "
import json, os, urllib.request
body = json.dumps({
    'gateway_url': os.environ['MB_URL'],
    'gateway_api_key': os.environ['MB_KEY'],
    'gateway_model': 'opus',
}).encode()
req = urllib.request.Request('http://localhost:4010/settings/gateway', data=body,
                             method='PUT', headers={'Content-Type': 'application/json'})
print(urllib.request.urlopen(req, timeout=30).read().decode())
"

if [ "$LOGGED_IN" = true ]; then
  say "Running a real test completion through the saved settings"
  RESULT=$($KUBECTL -n "$NS" exec deploy/model-builder -- python -c "
import urllib.request
req = urllib.request.Request('http://localhost:4010/settings/gateway/test', data=b'', method='POST')
print(urllib.request.urlopen(req, timeout=180).read().decode())
")
  echo "$RESULT"
  echo "$RESULT" | grep -q '\"ok\":[ ]*true' || die "test completion failed; check the gateway logs"
fi

# ── summary ──────────────────────────────────────────────────────────────
NODE_IP=$($KUBECTL get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
say "Done"
echo "UI:            http://$NODE_IP:30410"
echo "Gateway key:   $KUBECTL -n $NS get secret gateway-secrets -o jsonpath='{.data.CSG_API_KEY}' | base64 -d"
echo "Admin UI:      $KUBECTL -n $NS port-forward svc/claude-subscription-gateway 8790:8790  ->  http://localhost:8790/admin"
if [ "$LOGGED_IN" != true ]; then
  echo
  echo "STILL TO DO: connect the Claude subscription, then re-run this script to verify:"
  echo "  $KUBECTL -n $NS exec -it deploy/claude-subscription-gateway -- claude setup-token"
fi
