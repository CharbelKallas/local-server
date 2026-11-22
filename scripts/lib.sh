# shellcheck shell=sh
# Globals set here (PINNED_FILE, ...) are read by the sourcing script.
# shellcheck disable=SC2034
# Shared helpers for the scripts in this directory. Source it, don't run it:
#
#   . "$(dirname -- "$0")/lib.sh"
#
# Every cluster command goes through `kc` / `hc`, which pin the kube context
# explicitly. Relying on kubectl's *current* context is dangerous: if it
# happens to point at another cluster (Docker Desktop, a work cluster, ...),
# `make argocd-install` would happily install into it.
#
# Overridable via environment:
#   VM_NAME       Lima instance name          (default: k3s)
#   KUBE_CONTEXT  kubeconfig context to use   (default: k3s-lab)
#   SECRETS_DIR   where generated credentials live (default: <repo>/secrets)
#   CACHE_DIR     verified downloads kept for re-runs (default: <repo>/.cache)

VM_NAME="${VM_NAME:-k3s}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3s-lab}"
REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SECRETS_DIR="${SECRETS_DIR:-$REPO_ROOT/secrets}"
CACHE_DIR="${CACHE_DIR:-$REPO_ROOT/.cache}"

die() {
  echo "$*" >&2
  exit 1
}

# kubectl / helm bound to the lab context.
kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }
hc() { helm --kube-context "$KUBE_CONTEXT" "$@"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found. ${2:-Install it first.}"
}

# Fail fast unless the lab context exists and its API server answers.
require_cluster() {
  require_cmd kubectl
  if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx -- "$KUBE_CONTEXT"; then
    die "kubeconfig context '$KUBE_CONTEXT' not found (see docs/k3s.md, or set KUBE_CONTEXT)."
  fi
  kc get nodes >/dev/null 2>&1 || die "Cannot reach the cluster (context '$KUBE_CONTEXT'). Run: make k3s-start"
}

# Lima instance state: prints e.g. "Running" / "Stopped", or nothing if absent.
vm_status() {
  limactl list --format '{{.Status}}' "$VM_NAME" 2>/dev/null || true
}

vm_exists() { [ -n "$(vm_status)" ]; }

require_vm_running() {
  require_cmd limactl
  status=$(vm_status)
  [ -n "$status" ] || die "VM '$VM_NAME' does not exist. Run: make vm-start"
  [ "$status" = "Running" ] || die "VM '$VM_NAME' is not running. Run: make vm-start"
}

# Random alphanumeric secret of length $1 (default 32).
gen_secret() {
  # base64 of 48 random bytes is 64 chars; stripping =+/ never drops it below 32.
  openssl rand -base64 48 | tr -d '=+/\n' | head -c "${1:-32}"
}

# sha256 of file $1 (sha256sum on Linux, shasum on macOS). Dies if the
# file cannot be hashed, so a failure never reads as an empty hash.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    hash_out=$(sha256sum "$1") || die "Could not compute the sha256 of '$1'."
  elif command -v shasum >/dev/null 2>&1; then
    hash_out=$(shasum -a 256 "$1") || die "Could not compute the sha256 of '$1'."
  else
    die "Neither sha256sum nor shasum found: cannot verify downloads."
  fi
  echo "${hash_out%% *}"
}

# use_pinned_download <source> <sha256> <variable name>
# Sets PINNED_FILE to a local file whose sha256 is the pinned one, and dies
# otherwise. Used for every downloaded artifact: the Argo CD and
# cert-manager manifests, the K3s installer and the Kargo chart package.
# <source> is the default release URL or an override (a local file, or
# another https URL such as a mirror). A URL is downloaded to $PINNED_TMP
# first (callers remove it on exit), over https only — also for redirects —
# because the result runs as root or is applied with cluster-admin rights.
# Comparing the whole file's hash (not a version string inside it) means a
# modified copy, another release, or a re-tagged upstream file is refused.
PINNED_FILE=""
PINNED_TMP=""
use_pinned_download() {
  src=$1 sha=$2 var=$3
  case "$src" in
    https://*)
      require_cmd curl
      PINNED_TMP=$(mktemp)
      curl -fsSL --proto =https --proto-redir =https -o "$PINNED_TMP" "$src" \
        || die "$var: could not download '$src'."
      file=$PINNED_TMP
      ;;
    *://*) die "$var '$src': only https:// URLs are allowed." ;;
    *)
      if [ ! -f "$src" ] || [ ! -r "$src" ]; then
        die "$var '$src' is not a readable file."
      fi
      file=$src
      ;;
  esac
  # Assigned on its own line so a failure (no hash tool, unreadable file)
  # stops `set -e` callers instead of reading as a "mismatching" hash.
  actual=$(sha256_of "$file")
  [ "$actual" = "$sha" ] \
    || die "$var '$src' has sha256 $actual, expected $sha (not the pinned release, or modified)."
  PINNED_FILE=$file
}

# Forget database credentials inherited from the caller's environment, so
# only values from secrets/databases.env (or freshly generated ones) count:
# an exported REDIS_PASSWORD from another project must never stand in for a
# key missing from the file.
clear_db_credentials() {
  unset POSTGRES_PASSWORD MONGODB_USERNAME MONGODB_PASSWORD REDIS_PASSWORD \
    APP_POSTGRES_PASSWORD APP_MONGODB_PASSWORD APP_REDIS_PASSWORD
}

# Database credentials end up in a shell-sourced file, space-separated
# redis.conf lines and a mongodb:// URI, so they are limited to characters
# that are literal in all three (RFC 3986 "unreserved"), optionally inside
# matching quotes. Generated values are alphanumeric; this catches
# hand-edited ones. Prints line numbers, never values.
check_db_credentials_file() {
  if grep -q "$(printf '\r')" "$1"; then
    die "$1 has Windows (CRLF) line endings, which would end up inside the passwords. Convert it: tr -d '\\r' < '$1' > '$1.new' && mv '$1.new' '$1'"
  fi
  set_='[A-Za-z0-9._~-]*'
  bad=$(grep -nvE "^(#.*|[A-Z_][A-Z0-9_]*=($set_|\"$set_\"|'$set_'))?\$" "$1" | cut -d: -f1 | tr '\n' ' ')
  [ -z "$bad" ] || die "$1: line(s) ${bad% } must be KEY=value with values made of A-Z a-z 0-9 . _ ~ - only (optionally in quotes)."
}

# Same for the Kargo admin credentials (secrets/kargo-admin.env).
clear_kargo_credentials() {
  unset KARGO_ADMIN_PASSWORD KARGO_ADMIN_PASSWORD_HASH KARGO_TOKEN_SIGNING_KEY
}

# Create the gitignored secrets/ directory with owner-only permissions.
ensure_secrets_dir() {
  mkdir -p "$SECRETS_DIR"
  chmod 700 "$SECRETS_DIR"
}
