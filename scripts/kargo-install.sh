#!/bin/sh
# Install (or update) Kargo in the K3s cluster using the official Helm chart.
#
# Kargo is the continuous *promotion* layer for GitOps. It does not deploy
# anything itself: it advances artifacts through environments (here: dev ->
# staging) and lets Argo CD do the actual deploying from Git.
#
# Handled by this script:
#   * cert-manager  — required by the chart's default configuration, which
#     issues self-signed TLS certs for the API server and webhook servers.
#   * Admin credentials — bcrypt password hash + token signing key are
#     mandatory chart values. They are generated once and kept in
#     secrets/kargo-admin.env (gitignored); re-runs reuse them so the
#     admin password and issued tokens stay stable.
#
# The Kargo API server (which also serves the web UI) is exposed on
# NodePort 30090. Lima forwards guest ports 30000-32767 to the same ports
# on the macOS host (see vm/k3s.yaml), so the UI is reachable directly at
# https://localhost:30090 — same mechanism as Argo CD's NodePort 30080.
#
# Deliberately minimal: no Projects/Stages/Warehouses are created, no Argo
# Rollouts, no databases, no ingress — just the Kargo control plane.
#
# Idempotent: safe to re-run.
set -eu

NAMESPACE="kargo"
RELEASE="kargo"
CHART="oci://ghcr.io/akuity/kargo-charts/kargo"
CHART_VERSION="1.12.1"          # keep in sync with docs/kargo.md
CERT_MANAGER_VERSION="v1.21.2"  # keep in sync with docs/kargo.md
API_NODE_PORT="30090"

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CRED_FILE="$REPO_ROOT/secrets/kargo-admin.env"

if ! kubectl get nodes >/dev/null 2>&1; then
  echo "Cannot reach the K3s cluster. Run: make k3s-start" >&2
  exit 1
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "helm not found. Install it first (e.g. brew install helm)." >&2
  exit 1
fi

# --- cert-manager (dependency of Kargo's default configuration) ------------
if kubectl get deploy -n cert-manager cert-manager >/dev/null 2>&1; then
  echo "cert-manager already installed — leaving it untouched."
else
  echo "Installing cert-manager $CERT_MANAGER_VERSION (required by Kargo)..."
  # Server-side apply: cert-manager's CRDs exceed the 256 KiB
  # last-applied-configuration annotation limit of client-side apply.
  kubectl apply --server-side --force-conflicts \
    -f "https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml"
fi

echo "Waiting for cert-manager to become ready..."
kubectl wait --for=condition=Available deploy --all -n cert-manager --timeout=300s

# --- admin account credentials (generated once, reused on re-runs) --------
if [ -f "$CRED_FILE" ]; then
  echo "Reusing existing Kargo admin credentials ($CRED_FILE)."
else
  echo "Generating Kargo admin credentials -> $CRED_FILE"
  pass=$(openssl rand -base64 48 | tr -d "=+/" | head -c 32)
  # bcrypt hash as required by api.adminAccount.passwordHash.
  hashed_pass=$(htpasswd -bnBC 10 "" "$pass" | tr -d ':\n')
  signing_key=$(openssl rand -base64 48 | tr -d "=+/" | head -c 32)

  mkdir -p "$(dirname "$CRED_FILE")"
  # The hash contains '$' characters, so quote it literally when storing it;
  # the file is sourced by kargo-password.sh.
  {
    printf 'KARGO_ADMIN_PASSWORD=%s\n' "$pass"
    printf "KARGO_ADMIN_PASSWORD_HASH='%s'\n" "$hashed_pass"
    printf 'KARGO_TOKEN_SIGNING_KEY=%s\n' "$signing_key"
  } > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
fi

# shellcheck disable=SC1090
. "$CRED_FILE"

if [ -z "${KARGO_ADMIN_PASSWORD_HASH:-}" ] || [ -z "${KARGO_TOKEN_SIGNING_KEY:-}" ]; then
  echo "Invalid credentials file: $CRED_FILE (delete it and re-run)." >&2
  exit 1
fi

# --- install Kargo ---------------------------------------------------------
echo "Installing Kargo $CHART_VERSION (Helm release '$RELEASE', namespace '$NAMESPACE')..."
helm upgrade --install "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" --create-namespace \
  --version "$CHART_VERSION" \
  --set-string "api.adminAccount.passwordHash=$KARGO_ADMIN_PASSWORD_HASH" \
  --set-string "api.adminAccount.tokenSigningKey=$KARGO_TOKEN_SIGNING_KEY" \
  --set "api.service.type=NodePort" \
  --set "api.service.nodePort=$API_NODE_PORT" \
  --wait --timeout 10m

echo "Waiting for Kargo workloads to become available..."
# Wait on Deployments, not on every Pod in the namespace: the
# kargo-garbage-collector CronJob leaves `Completed` pods behind, and a
# finished pod never satisfies Ready, which would stall this wait for the
# full timeout and then fail.
kubectl wait --for=condition=Available deploy --all -n "$NAMESPACE" --timeout=300s

# The manifest pin above is the source of truth for the UI address — verify
# it so a chart change can't silently break the documented URL.
if [ "$(kubectl get svc kargo-api -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}')" != "$API_NODE_PORT" ]; then
  echo "Failed to expose kargo-api on NodePort $API_NODE_PORT." >&2
  exit 1
fi

echo
echo "Kargo is installed."
echo "UI:     https://localhost:$API_NODE_PORT   (user: admin, password: make kargo-password)"
echo "Pods:   kubectl get pods -n $NAMESPACE"
echo "Status: make kargo-status"
