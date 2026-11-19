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
#     secrets/kargo-admin.env (gitignored, mode 600); re-runs reuse them so
#     the admin password and issued tokens stay stable. They are handed to
#     Helm through a private temporary values file, never on the command
#     line (where any local user could read them with `ps`).
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
. "$(dirname -- "$0")/lib.sh"

NAMESPACE="kargo"
RELEASE="kargo"
CHART_VERSION="1.12.1"          # keep in sync with docs/kargo.md
# sha256 of that chart's package (kargo-1.12.1.tgz) — update with the version.
CHART_SHA256="d152209bc01fe7577285ecc1803e4dac4832ec6e7a7724a89351dbf799d43d6a"
CERT_MANAGER_VERSION="v1.21.3"  # keep in sync with docs/kargo.md
# sha256 of that release's cert-manager.yaml — update together with the version.
CERT_MANAGER_SHA256="c04a51295adda2b1a775146751f973e787190778c7f35180861d9678876e5c74"
API_NODE_PORT="30090"
# Optional other copies of the same pinned artifacts (offline installs, a
# mirror, or the e2e test reusing its one download):
# KARGO_CHART = a packaged chart (.tgz from `helm pull`) or another chart
#   reference (OCI or `repo/chart`, pulled at --version),
# CERT_MANAGER_MANIFEST = a cert-manager.yaml file or https URL.
# Both are sha256-checked, like the defaults.
CHART="${KARGO_CHART:-oci://ghcr.io/akuity/kargo-charts/kargo}"
DEFAULT_CERT_MANAGER_MANIFEST="https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml"
CRED_FILE="$SECRETS_DIR/kargo-admin.env"

require_cluster
require_cmd helm "Install it first (e.g. brew install helm)."
require_cmd openssl
require_cmd htpasswd

# Temp files (credentials, values, a downloaded manifest) hold
# real secrets or unverified downloads: always remove them, even on Ctrl-C. (EXIT
# does the cleanup; INT/TERM must exit explicitly, or a bare handler would
# run the cleanup and then let the script carry on.)
tmp_cred=""
values_file=""
chart_dir=""
cleanup() {
  rm -f "$tmp_cred" "$values_file" "$PINNED_TMP"
  [ -z "$chart_dir" ] || rm -rf "$chart_dir"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- Kargo chart (pinned by sha256) -----------------------------------------
# A tag such as 1.12.1 can be re-pushed, so the chart package is fetched
# first and must match CHART_SHA256 — the same check as for the manifests.
# A chart reference (the default OCI one, or a mirror) is pulled at the
# pinned version; a .tgz on disk is checked as it is.
if [ -e "$CHART" ]; then
  chart_file=$CHART
else
  chart_dir=$(mktemp -d)
  hc pull "$CHART" --version "$CHART_VERSION" -d "$chart_dir" >/dev/null \
    || die "KARGO_CHART: could not pull '$CHART' version $CHART_VERSION."
  chart_file=$(find "$chart_dir" -name '*.tgz' | head -n 1)
  [ -n "$chart_file" ] || die "KARGO_CHART: pulling '$CHART' produced no chart package."
fi
use_pinned_manifest "$chart_file" "$CHART_SHA256" KARGO_CHART
chart_file=$PINNED_MANIFEST

# --- cert-manager (dependency of Kargo's default configuration) ------------
# Only a definite NotFound means "not installed". Any other error (API
# unreachable, RBAC, timeout) must stop here: treating it as "missing" would
# force-apply this cert-manager over one that something else manages.
if cm_probe=$(kc get deploy -n cert-manager cert-manager -o name 2>&1); then
  echo "cert-manager already installed — leaving it untouched."
else
  case "$cm_probe" in
    *NotFound*) ;;
    *) die "Could not check for an existing cert-manager: $cm_probe" ;;
  esac
  echo "Installing cert-manager $CERT_MANAGER_VERSION (required by Kargo)..."
  use_pinned_manifest "${CERT_MANAGER_MANIFEST:-$DEFAULT_CERT_MANAGER_MANIFEST}" \
    "$CERT_MANAGER_SHA256" CERT_MANAGER_MANIFEST
  # Server-side apply: cert-manager's CRDs exceed the 256 KiB
  # last-applied-configuration annotation limit of client-side apply.
  kc apply --server-side --force-conflicts \
    -f "$PINNED_MANIFEST"
fi

echo "Waiting for cert-manager to become ready..."
kc wait --for=condition=Available deploy --all -n cert-manager --timeout=300s

# --- admin account credentials (generated once, reused on re-runs) --------
umask 077
# Also tightens a secrets/ directory created by older versions (0755).
ensure_secrets_dir
if [ -f "$CRED_FILE" ]; then
  echo "Reusing existing Kargo admin credentials ($CRED_FILE)."
else
  echo "Generating Kargo admin credentials -> $CRED_FILE"
  pass=$(gen_secret 32)
  # bcrypt hash as required by api.adminAccount.passwordHash. -i reads the
  # password from stdin so it never appears in the process list.
  hashed_pass=$(printf '%s' "$pass" | htpasswd -inBC 10 "" | tr -d ':\n')
  signing_key=$(gen_secret 32)
  # shellcheck disable=SC2016  # literal '$2' prefix of a bcrypt hash
  case "$hashed_pass" in
    '$2'*) ;;
    *) die "htpasswd did not produce a bcrypt hash." ;;
  esac

  # The hash contains '$' characters, so quote it literally when storing it;
  # the file is sourced by this script and by kargo-password.sh.
  tmp_cred=$(mktemp "$CRED_FILE.XXXXXX")
  {
    printf 'KARGO_ADMIN_PASSWORD=%s\n' "$pass"
    printf "KARGO_ADMIN_PASSWORD_HASH='%s'\n" "$hashed_pass"
    printf 'KARGO_TOKEN_SIGNING_KEY=%s\n' "$signing_key"
  } > "$tmp_cred"
  mv "$tmp_cred" "$CRED_FILE"
  tmp_cred=""
fi
chmod 600 "$CRED_FILE"

clear_kargo_credentials
# shellcheck disable=SC1090
. "$CRED_FILE"

if [ -z "${KARGO_ADMIN_PASSWORD_HASH:-}" ] || [ -z "${KARGO_TOKEN_SIGNING_KEY:-}" ]; then
  die "Invalid credentials file: $CRED_FILE (delete it and re-run)."
fi

# --- install Kargo ---------------------------------------------------------
values_file=$(mktemp)
# Both values are generated by this script: the hash is [$./0-9A-Za-z] and
# the key is alphanumeric, so single-quoted YAML scalars are safe.
cat > "$values_file" <<VALUES
api:
  adminAccount:
    passwordHash: '$KARGO_ADMIN_PASSWORD_HASH'
    tokenSigningKey: '$KARGO_TOKEN_SIGNING_KEY'
  service:
    type: NodePort
    nodePort: $API_NODE_PORT
VALUES

echo "Installing Kargo $CHART_VERSION (Helm release '$RELEASE', namespace '$NAMESPACE')..."
hc upgrade --install "$RELEASE" "$chart_file" \
  --namespace "$NAMESPACE" --create-namespace \
  --values "$values_file" \
  --wait --timeout 10m

echo "Waiting for Kargo workloads to become available..."
# Wait on Deployments, not on every Pod in the namespace: the
# kargo-garbage-collector CronJob leaves `Completed` pods behind, and a
# finished pod never satisfies Ready.
kc wait --for=condition=Available deploy --all -n "$NAMESPACE" --timeout=300s

# Verify the documented UI address so a chart change can't silently break it.
if [ "$(kc get svc kargo-api -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}')" != "$API_NODE_PORT" ]; then
  die "Failed to expose kargo-api on NodePort $API_NODE_PORT."
fi

echo
echo "Kargo is installed."
echo "UI:     https://localhost:$API_NODE_PORT   (user: admin, password: make kargo-password)"
echo "Pods:   kubectl --context $KUBE_CONTEXT get pods -n $NAMESPACE"
echo "Status: make kargo-status"
