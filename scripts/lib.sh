# shellcheck shell=sh
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

VM_NAME="${VM_NAME:-k3s}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3s-lab}"
REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SECRETS_DIR="${SECRETS_DIR:-$REPO_ROOT/secrets}"

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

# Create the gitignored secrets/ directory with owner-only permissions.
ensure_secrets_dir() {
  mkdir -p "$SECRETS_DIR"
  chmod 700 "$SECRETS_DIR"
}
