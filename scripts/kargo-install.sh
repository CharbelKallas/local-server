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
CERT_MANAGER_VERSION="v1.21.3"  # keep in sync with docs/kargo.md
API_NODE_PORT="30090"
# Optional other copies of the same pinned artifacts (offline installs, a
# mirror, or the e2e test reusing its one download), both version-checked:
# KARGO_CHART = a packaged chart (.tgz from `helm pull`) or another OCI ref,
# CERT_MANAGER_MANIFEST = a cert-manager.yaml file or URL.
CHART="${KARGO_CHART:-oci://ghcr.io/akuity/kargo-charts/kargo}"
DEFAULT_CERT_MANAGER_MANIFEST="https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml"
CRED_FILE="$SECRETS_DIR/kargo-admin.env"

require_cluster
require_cmd helm "Install it first (e.g. brew install helm)."

# --version only applies to a registry chart. A local chart (.tgz) carries
# its own version, which must be the pinned one: otherwise Helm would
# silently up- or downgrade Kargo while this script reports $CHART_VERSION.
version_flag=""
case "$CHART" in
  oci://*) version_flag="--version=$CHART_VERSION" ;;
  *)
    local_version=$(helm show chart "$CHART" 2>/dev/null | sed -n 's/^version: *//p')
    [ "$local_version" = "$CHART_VERSION" ] \
      || die "KARGO_CHART '$CHART' is Kargo chart '${local_version:-unreadable}', expected $CHART_VERSION."
    ;;
esac
require_cmd openssl
require_cmd htpasswd

# Temp files (credentials, values, a downloaded manifest override) hold
# real secrets or unverified downloads: always remove them, even on Ctrl-C. (EXIT
# does the cleanup; INT/TERM must exit explicitly, or a bare handler would
# run the cleanup and then let the script carry on.)
tmp_cred=""
values_file=""
cleanup() { rm -f "$tmp_cred" "$values_file" "$PINNED_TMP"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- cert-manager (dependency of Kargo's default configuration) ------------
if kc get deploy -n cert-manager cert-manager >/dev/null 2>&1; then
  echo "cert-manager already installed — leaving it untouched."
else
  echo "Installing cert-manager $CERT_MANAGER_VERSION (required by Kargo)..."
  use_pinned_manifest "${CERT_MANAGER_MANIFEST:-$DEFAULT_CERT_MANAGER_MANIFEST}" \
    "$DEFAULT_CERT_MANAGER_MANIFEST" \
    "quay.io/jetstack/cert-manager-controller:$CERT_MANAGER_VERSION" CERT_MANAGER_MANIFEST
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
# shellcheck disable=SC2086  # empty for a local chart, one word otherwise
hc upgrade --install "$RELEASE" "$CHART" $version_flag \
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
