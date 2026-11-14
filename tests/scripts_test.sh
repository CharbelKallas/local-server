#!/bin/sh
# Unit tests for scripts/*.sh. No VM or cluster needed: kubectl, helm and
# limactl are replaced by stubs (tests/stubs/) that record every call to a
# log file and answer from environment variables. Real openssl/htpasswd are
# used, so generated credentials are real.
#
# Run: make test   (or tests/scripts_test.sh)
set -u

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPTS="$REPO_ROOT/scripts"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM

PATH="$REPO_ROOT/tests/stubs:$PATH"
export PATH

PASS=0
FAIL=0
CURRENT=""

# --- tiny test framework ------------------------------------------------------

# Fresh, isolated state for each test.
setup() {
  CURRENT=$1
  rm -rf "$WORK/case"
  mkdir -p "$WORK/case"
  STUB_LOG="$WORK/case/calls.log"
  SECRETS_DIR="$WORK/case/secrets"
  : > "$STUB_LOG"
  export STUB_LOG SECRETS_DIR
  # Defaults: a healthy, reachable lab cluster in a running VM.
  export STUB_CONTEXTS="k3s-lab"
  export STUB_NODES_RC=0
  export STUB_VM_STATUS="Running"
  export STUB_NODEPORT=""
  export STUB_PVCS=""
  unset KUBE_CONTEXT VM_NAME K3S_VERSION ARGOCD_VERSION
}

fail() {
  echo "  FAIL [$CURRENT]: $*"
  FAIL=$((FAIL + 1))
}

ok() { PASS=$((PASS + 1)); }

# run <script> [args...] — captures stdout+stderr in $OUT and exit code in $RC
run() {
  script=$1
  shift
  OUT=$("$SCRIPTS/$script" "$@" 2>&1)
  RC=$?
}

assert_rc() {
  if [ "$RC" -eq "$1" ]; then ok; else fail "exit code $RC, expected $1. Output:
$OUT"; fi
}

assert_out_contains() {
  case "$OUT" in
    *"$1"*) ok ;;
    *) fail "output does not contain '$1'. Output:
$OUT" ;;
  esac
}

assert_log_contains() {
  if grep -qF -- "$1" "$STUB_LOG"; then ok; else fail "no call matching '$1'. Calls:
$(cat "$STUB_LOG")"; fi
}

assert_log_not_contains() {
  if grep -qF -- "$1" "$STUB_LOG"; then fail "unexpected call matching '$1'. Calls:
$(cat "$STUB_LOG")"; else ok; fi
}

# Every kubectl/helm invocation must carry the expected context, except
# `kubectl config ...` (reading the kubeconfig itself).
assert_all_calls_pinned_to() {
  ctx=$1
  bad=$(grep -E '^(kubectl|helm) ' "$STUB_LOG" \
    | grep -v '^kubectl config ' \
    | grep -v -e "--context $ctx" -e "--kube-context $ctx" || true)
  if [ -z "$bad" ]; then ok; else fail "calls without context '$ctx':
$bad"; fi
}

# A secret value must never appear in any command's argv (only in file
# contents the stubs record on separate CONTENT lines).
assert_not_in_argv() {
  if grep -v '^CONTENT ' "$STUB_LOG" | grep -qF -- "$1"; then
    fail "secret value appeared on a command line"
  else ok; fi
}

file_mode() {
  if stat -f %Lp "$1" >/dev/null 2>&1; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

# --- cluster guard ------------------------------------------------------------

setup "argocd-install refuses when the lab context is missing"
STUB_CONTEXTS="docker-desktop"
run argocd-install.sh
assert_rc 1
assert_out_contains "context 'k3s-lab' not found"
assert_log_not_contains "apply"

setup "argocd-install refuses when the cluster is unreachable"
STUB_NODES_RC=1
run argocd-install.sh
assert_rc 1
assert_out_contains "Cannot reach the cluster"
assert_log_not_contains "apply"

setup "status scripts refuse on the wrong cluster"
STUB_CONTEXTS="some-other-cluster"
for s in argocd-status.sh argocd-password.sh argocd-ui.sh kargo-status.sh databases-status.sh; do
  run "$s"
  assert_rc 1
done
assert_log_not_contains "get pods"

# --- Argo CD ------------------------------------------------------------------

setup "argocd-install: pinned manifest, explicit context, NodePort patch"
STUB_NODEPORT=30080
run argocd-install.sh
assert_rc 0
assert_log_contains "https://raw.githubusercontent.com/argoproj/argo-cd/v3.6.1/manifests/install.yaml"
assert_log_not_contains "argo-cd/stable/"
assert_log_contains '"ports":[{"port":443,"nodePort":30080}]'
assert_log_contains "rollout status deploy -n argocd"
assert_all_calls_pinned_to k3s-lab

setup "argocd-install: KUBE_CONTEXT override is honoured everywhere"
STUB_CONTEXTS="k3s-lab
lab-two"
STUB_NODEPORT=30080
KUBE_CONTEXT=lab-two run argocd-install.sh
assert_rc 0
assert_all_calls_pinned_to lab-two

setup "argocd-install: fails if the NodePort did not stick"
STUB_NODEPORT=31234
run argocd-install.sh
assert_rc 1
assert_out_contains "Failed to expose"

setup "argocd-password: decodes the initial admin secret"
STUB_SECRET_B64=$(printf 's3cr3t' | base64)
export STUB_SECRET_B64
run argocd-password.sh
assert_rc 0
assert_out_contains "Initial admin password: s3cr3t"
unset STUB_SECRET_B64

setup "argocd-password: explains a missing secret"
run argocd-password.sh
assert_rc 1
assert_out_contains "Reset the Admin Password"

# --- Kargo --------------------------------------------------------------------

setup "kargo-install: generates private credentials and keeps them off argv"
run kargo-install.sh
assert_rc 0
cred="$SECRETS_DIR/kargo-admin.env"
if [ -f "$cred" ]; then ok; else fail "credentials file not created"; fi
if [ "$(file_mode "$cred")" = "600" ]; then ok; else fail "credentials file mode is $(file_mode "$cred"), expected 600"; fi
if [ "$(file_mode "$SECRETS_DIR")" = "700" ]; then ok; else fail "secrets dir mode is $(file_mode "$SECRETS_DIR"), expected 700"; fi
# shellcheck disable=SC1090,SC1091
. "$cred"
# shellcheck disable=SC2016  # literal bcrypt prefix
case "$KARGO_ADMIN_PASSWORD_HASH" in '$2'*) ok ;; *) fail "hash is not bcrypt" ;; esac
if [ "${#KARGO_ADMIN_PASSWORD}" -eq 32 ]; then ok; else fail "password length ${#KARGO_ADMIN_PASSWORD}"; fi
printf 'admin:%s\n' "$KARGO_ADMIN_PASSWORD_HASH" > "$WORK/case/htpasswd"
if htpasswd -vb "$WORK/case/htpasswd" admin "$KARGO_ADMIN_PASSWORD" >/dev/null 2>&1; then ok; else fail "bcrypt hash does not match the stored password"; fi
assert_log_contains "--version 1.12.1"
assert_log_contains "--values"
assert_log_contains "CONTENT passwordHash: '$KARGO_ADMIN_PASSWORD_HASH'"
assert_log_contains "CONTENT nodePort: 30090"
assert_not_in_argv "$KARGO_ADMIN_PASSWORD_HASH"
assert_not_in_argv "$KARGO_TOKEN_SIGNING_KEY"
assert_not_in_argv "$KARGO_ADMIN_PASSWORD"
assert_all_calls_pinned_to k3s-lab
values_path=$(sed -n 's/^HELM_VALUES_FILE //p' "$STUB_LOG")
if [ -n "$values_path" ] && [ ! -e "$values_path" ]; then ok; else fail "temporary values file was not removed ($values_path)"; fi

setup "kargo-install: re-runs reuse the same credentials"
run kargo-install.sh
first=$(cat "$SECRETS_DIR/kargo-admin.env")
run kargo-install.sh
assert_rc 0
assert_out_contains "Reusing existing Kargo admin credentials"
if [ "$first" = "$(cat "$SECRETS_DIR/kargo-admin.env")" ]; then ok; else fail "credentials changed on re-run"; fi

setup "kargo-password: prints the stored password"
run kargo-install.sh
# shellcheck disable=SC1090,SC1091
. "$SECRETS_DIR/kargo-admin.env"
run kargo-password.sh
assert_rc 0
assert_out_contains "Kargo admin password: $KARGO_ADMIN_PASSWORD"

setup "kargo-password: no credentials yet"
run kargo-password.sh
assert_rc 1
assert_out_contains "Run: make kargo-install"

# --- databases ----------------------------------------------------------------

setup "databases-install: secrets from generated credentials, none on argv"
run databases-install.sh
assert_rc 0
cred="$SECRETS_DIR/databases.env"
if [ "$(file_mode "$cred")" = "600" ]; then ok; else fail "credentials file mode is $(file_mode "$cred")"; fi
# shellcheck disable=SC1090,SC1091
. "$cred"
assert_log_contains "CONTENT secret postgres-credentials password=$POSTGRES_PASSWORD"
assert_log_contains "CONTENT secret mongodb-credentials username=root"
assert_log_contains "CONTENT secret mongodb-credentials password=$MONGODB_PASSWORD"
assert_log_contains "CONTENT secret redis-credentials password=$REDIS_PASSWORD"
assert_log_contains "CONTENT secret redis-credentials redis.conf=requirepass $REDIS_PASSWORD"
assert_not_in_argv "$POSTGRES_PASSWORD"
assert_not_in_argv "$MONGODB_PASSWORD"
assert_not_in_argv "$REDIS_PASSWORD"
assert_log_contains "apply -k $REPO_ROOT/kubernetes/databases"
for app in postgres mongodb redis; do
  assert_log_contains "rollout status deploy/$app -n databases"
done
assert_all_calls_pinned_to k3s-lab
if [ "$POSTGRES_PASSWORD" != "$REDIS_PASSWORD" ]; then ok; else fail "passwords are not independent"; fi

setup "databases-install: refuses to pair new passwords with existing volumes"
STUB_PVCS="persistentvolumeclaim/postgres-data"
run databases-install.sh
assert_rc 1
assert_out_contains "Existing database volumes found"
if [ ! -e "$SECRETS_DIR/databases.env" ]; then ok; else fail "unused credentials file left behind"; fi
assert_log_not_contains "apply -k"

setup "databases-install: existing volumes are fine when credentials exist"
run databases-install.sh
STUB_PVCS="persistentvolumeclaim/postgres-data
persistentvolumeclaim/mongodb-data"
: > "$STUB_LOG"
run databases-install.sh
assert_rc 0
assert_log_contains "apply -k"

setup "databases-password: prints all three credentials"
run databases-install.sh
# shellcheck disable=SC1090,SC1091
. "$SECRETS_DIR/databases.env"
run databases-password.sh
assert_rc 0
assert_out_contains "$POSTGRES_PASSWORD"
assert_out_contains "$MONGODB_PASSWORD"
assert_out_contains "$REDIS_PASSWORD"

# --- VM / K3s -----------------------------------------------------------------

setup "vm-ssh: missing VM"
STUB_VM_STATUS=""
run vm-ssh.sh
assert_rc 1
assert_out_contains "does not exist. Run: make vm-start"

setup "vm-ssh: stopped VM"
STUB_VM_STATUS="Stopped"
run vm-ssh.sh uname -a
assert_rc 1
assert_out_contains "is not running"
assert_log_not_contains "limactl shell"

setup "vm-ssh: runs a command in the VM"
run vm-ssh.sh uname -a
assert_rc 0
assert_log_contains "limactl shell k3s -- bash -lc uname -a"

setup "vm-start: creates a missing VM from vm/k3s.yaml"
STUB_VM_STATUS=""
run vm-start.sh
assert_rc 0
assert_log_contains "limactl start --name=k3s $REPO_ROOT/vm/k3s.yaml"

setup "vm-start: starts an existing VM"
STUB_VM_STATUS="Stopped"
run vm-start.sh
assert_rc 0
assert_log_contains "limactl start k3s"

setup "vm-stop / k3s-stop: no-ops when the VM is absent or stopped"
for st in "" "Stopped"; do
  STUB_VM_STATUS=$st
  run vm-stop.sh; assert_rc 0
  run k3s-stop.sh; assert_rc 0
done
assert_log_not_contains "limactl stop"
assert_log_not_contains "systemctl stop"

setup "k3s-start: installs the pinned K3s version when missing"
export STUB_K3S_INSTALLED=0
run k3s-start.sh
assert_rc 0
assert_log_contains "v1.36.5+k3s1"
assert_log_contains "systemctl start k3s"
unset STUB_K3S_INSTALLED

setup "k3s-status: reports an inactive service instead of crashing"
export STUB_K3S_ACTIVE=inactive
run k3s-status.sh
assert_rc 1
assert_out_contains "K3s is not running"
unset STUB_K3S_ACTIVE

# --- summary ------------------------------------------------------------------

echo
echo "scripts_test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
