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
  CACHE_DIR="$WORK/case/cache"
  : > "$STUB_LOG"
  export STUB_LOG SECRETS_DIR CACHE_DIR
  # Defaults: a healthy, reachable lab cluster in a running VM.
  export STUB_CONTEXTS="k3s-lab"
  export STUB_NODES_RC=0
  export STUB_VM_STATUS="Running"
  export STUB_NODEPORT=""
  export STUB_PVCS=""
  # Stub behaviours a test exports apply to that test only; overrides
  # from the developer's own shell must not leak in either. (Per-run
  # overrides go through `run NAME=value ...`, which never touches this shell.)
  unset STUB_PVC_RC STUB_APPLY_ACTION STUB_JOB_STATE STUB_SECRET_B64 STUB_K3S_INSTALLED \
    STUB_K3S_ACTIVE STUB_CURL_FILE KUBE_CONTEXT DB_APP_NAMESPACES ARGOCD_MANIFEST \
    KARGO_CHART CERT_MANAGER_MANIFEST STUB_CERT_MANAGER_MISSING STUB_CERT_MANAGER_ERROR STUB_CHART_FILE
}

fail() {
  echo "  FAIL [$CURRENT]: $*"
  FAIL=$((FAIL + 1))
}

ok() { PASS=$((PASS + 1)); }

# run <script> [args...] — captures stdout+stderr in $OUT and exit code in $RC
# run [NAME=value ...] <script> [args...] — captures stdout+stderr in $OUT
# and the exit code in $RC. Leading NAME=value arguments are exported only
# inside the command substitution's subshell, so — unlike `NAME=value run`,
# which POSIX sh may leave set in the test shell — they cannot leak into
# later tests.
run_in_subshell() {
  while [ $# -gt 0 ]; do
    # shellcheck disable=SC2163  # exports the NAME=value given in $1
    case "$1" in
      [A-Za-z_]*=*) export "$1"; shift ;;
      *) break ;;
    esac
  done
  script=$1
  shift
  "$SCRIPTS/$script" "$@"
}
run() {
  # The helper runs inside $(...), i.e. in a subshell: its exports end there.
  # (Kept out of the substitution itself: bash 3.2, macOS's /bin/sh, cannot
  # parse a case statement inside $(...).)
  OUT=$(run_in_subshell "$@" 2>&1)
  RC=$?
}

# sha256 of file $1, computed by the scripts' own helper (lib.sh).
sha256_file() {
  # In a separate shell, so lib.sh's globals never touch this one.
  # shellcheck disable=SC2016  # expanded by that shell
  sh -c '. "$1/lib.sh" && sha256_of "$2"' sh "$SCRIPTS" "$1"
}

# sha_pinned_scripts <script> <VAR> <file> [<VAR> <file> ...] — prints a
# copy of scripts/ in which each sha256 constant <VAR> of <script> is the
# sha256 of <file>, so a test can stand in a small fake for the real
# release artifact. Use it with `run SCRIPTS="$(sha_pinned_scripts ...)" ...`.
sha_pinned_scripts() {
  target=$1
  shift
  dir="$WORK/case/scripts"
  rm -rf "$dir"
  cp -R "$SCRIPTS" "$dir"
  while [ $# -ge 2 ]; do
    sha=$(sha256_file "$2")
    # cat > keeps the copy's executable bit.
    sed "s/^$1=\".*\"/$1=\"$sha\"/" "$dir/$target" > "$dir/$target.new"
    cat "$dir/$target.new" > "$dir/$target"
    rm -f "$dir/$target.new"
    grep -q "^$1=\"$sha\"" "$dir/$target" || echo "sha_pinned_scripts: no $1 in $target" >&2
    shift 2
  done
  echo "$dir"
}

# A stand-in for the Kargo chart package: the helm stub "pulls" it, and
# kargo_run runs kargo-install.sh with CHART_SHA256 pinned to it.
KARGO_FAKE_CHART="$WORK/kargo-1.12.1.tgz"
printf 'fake kargo chart\n' > "$KARGO_FAKE_CHART"
kargo_run() {
  run SCRIPTS="$(sha_pinned_scripts kargo-install.sh CHART_SHA256 "$KARGO_FAKE_CHART")" \
    STUB_CHART_FILE="$KARGO_FAKE_CHART" "$@"
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

assert_out_not_contains() {
  case "$OUT" in
    *"$1"*) fail "output unexpectedly contains '$1'. Output:
$OUT" ;;
    *) ok ;;
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

# Prints every kubectl/helm call in the log that is NOT pinned to context
# $1, except `kubectl config ...` (reading the kubeconfig). The context
# value is compared as a whole word, literally — no regex, so a name like
# "k3s.lab" cannot match "k3sXlab" and "k3s-lab" cannot match "k3s-lab-old".
unpinned_calls() {
  grep -E '^(kubectl|helm) ' "$STUB_LOG" \
    | grep -v '^kubectl config ' \
    | awk -v ctx="$1" '{
        pinned = 0
        for (i = 1; i < NF; i++)
          if (($i == "--context" || $i == "--kube-context") && $(i + 1) == ctx) pinned = 1
        if (!pinned) print
      }'
}

assert_all_calls_pinned_to() {
  bad=$(unpinned_calls "$1")
  if [ -z "$bad" ]; then ok; else fail "calls without context '$1':
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
printf 'kind: List\n' > "$WORK/case/upstream.yaml"
run SCRIPTS="$(sha_pinned_scripts argocd-install.sh ARGOCD_MANIFEST_SHA256 "$WORK/case/upstream.yaml")" \
  STUB_CURL_FILE="$WORK/case/upstream.yaml" argocd-install.sh
assert_rc 0
assert_log_contains "curl -fsSL --proto =https --proto-redir =https -o"
assert_log_contains "https://raw.githubusercontent.com/argoproj/argo-cd/v3.6.1/manifests/install.yaml"
assert_log_not_contains "argo-cd/stable/"
assert_log_not_contains "-f https://"
assert_log_contains '"ports":[{"port":443,"nodePort":30080}]'
assert_log_contains "rollout status deploy -n argocd"
assert_all_calls_pinned_to k3s-lab

setup "argocd-install: refuses an upstream manifest whose sha256 changed"
printf 'kind: List\n' > "$WORK/case/upstream.yaml"
run STUB_CURL_FILE="$WORK/case/upstream.yaml" argocd-install.sh
assert_rc 1
assert_out_contains "expected 7be23ca7d9ca3d3074dee8332f1ca92a933b990cee7c9cf22cf3843ee8c2913e"
assert_log_not_contains "apply --server-side"

setup "argocd-install: ARGOCD_MANIFEST file override, sha256-checked"
STUB_NODEPORT=30080
printf '        image: quay.io/argoproj/argocd:v3.6.1\n' > "$WORK/case/install.yaml"
run SCRIPTS="$(sha_pinned_scripts argocd-install.sh ARGOCD_MANIFEST_SHA256 "$WORK/case/install.yaml")" \
  ARGOCD_MANIFEST="$WORK/case/install.yaml" argocd-install.sh
assert_rc 0
assert_log_contains "-f $WORK/case/install.yaml"
assert_log_not_contains "curl "

setup "argocd-install: refuses a modified ARGOCD_MANIFEST, even with the pinned image"
# The pinned image line alone proves nothing about the rest of the file.
printf '        image: quay.io/argoproj/argocd:v3.6.1\n' > "$WORK/case/install.yaml"
run ARGOCD_MANIFEST="$WORK/case/install.yaml" argocd-install.sh
assert_rc 1
assert_out_contains "not the pinned release, or modified"
assert_log_not_contains "apply --server-side"

setup "argocd-install: an https URL override is downloaded and sha256-checked"
STUB_NODEPORT=30080
printf 'kind: List\n' > "$WORK/case/mirror.yaml"
run STUB_CURL_FILE="$WORK/case/mirror.yaml" ARGOCD_MANIFEST=https://mirror.example/install.yaml argocd-install.sh
assert_rc 1
assert_out_contains "not the pinned release, or modified"
assert_log_not_contains "apply --server-side"
: > "$STUB_LOG"
run SCRIPTS="$(sha_pinned_scripts argocd-install.sh ARGOCD_MANIFEST_SHA256 "$WORK/case/mirror.yaml")" \
  STUB_CURL_FILE="$WORK/case/mirror.yaml" ARGOCD_MANIFEST=https://mirror.example/install.yaml argocd-install.sh
assert_rc 0
assert_log_contains "--proto =https --proto-redir =https -o"
assert_log_contains "https://mirror.example/install.yaml"
assert_log_not_contains "-f https://mirror.example/install.yaml"

setup "argocd-install: a directory as ARGOCD_MANIFEST is not reported as tampering"
run ARGOCD_MANIFEST="$WORK/case" argocd-install.sh
assert_rc 1
assert_out_contains "is not a readable file"
assert_out_not_contains "not the pinned release"

setup "argocd-install: refuses a plain http:// override"
run ARGOCD_MANIFEST=http://mirror.example/install.yaml argocd-install.sh
assert_rc 1
assert_out_contains "only https:// URLs are allowed"
assert_log_not_contains "curl "
assert_log_not_contains "apply --server-side"

setup "kargo-install: refuses a CERT_MANAGER_MANIFEST of another version"
printf '        image: quay.io/jetstack/cert-manager-controller:v1.15.0\n' > "$WORK/case/cm.yaml"
kargo_run STUB_CERT_MANAGER_MISSING=1 CERT_MANAGER_MANIFEST="$WORK/case/cm.yaml" kargo-install.sh
assert_rc 1
assert_out_contains "expected c04a51295adda2b1a775146751f973e787190778c7f35180861d9678876e5c74"
assert_log_not_contains "upgrade --install"

setup "run NAME=value ... does not leak into the test shell"
run KARGO_CHART=/leak/test.tgz ARGOCD_MANIFEST=/leak/x.yaml kargo-password.sh
if [ -z "${KARGO_CHART:-}" ] && [ -z "${ARGOCD_MANIFEST:-}" ]; then ok
else fail "override leaked: KARGO_CHART='${KARGO_CHART:-}' ARGOCD_MANIFEST='${ARGOCD_MANIFEST:-}'"; fi

setup "argocd-install: KUBE_CONTEXT override is honoured everywhere"
STUB_CONTEXTS="k3s-lab
lab-two"
STUB_NODEPORT=30080
printf 'kind: List\n' > "$WORK/case/upstream.yaml"
run SCRIPTS="$(sha_pinned_scripts argocd-install.sh ARGOCD_MANIFEST_SHA256 "$WORK/case/upstream.yaml")" \
  STUB_CURL_FILE="$WORK/case/upstream.yaml" KUBE_CONTEXT=lab-two argocd-install.sh
assert_rc 0
assert_all_calls_pinned_to lab-two

setup "argocd-install: fails if the NodePort did not stick"
STUB_NODEPORT=31234
printf 'kind: List\n' > "$WORK/case/upstream.yaml"
run SCRIPTS="$(sha_pinned_scripts argocd-install.sh ARGOCD_MANIFEST_SHA256 "$WORK/case/upstream.yaml")" \
  STUB_CURL_FILE="$WORK/case/upstream.yaml" argocd-install.sh
assert_rc 1
assert_out_contains "Failed to expose"

setup "argocd-password: decodes the initial admin secret"
STUB_SECRET_B64=$(printf 's3cr3t' | base64)
export STUB_SECRET_B64
run argocd-password.sh
assert_rc 0
assert_out_contains "Initial admin password: s3cr3t"

setup "argocd-password: explains a missing secret"
run argocd-password.sh
assert_rc 1
assert_out_contains "Reset the Admin Password"

# --- Kargo --------------------------------------------------------------------

setup "kargo-install: generates private credentials and keeps them off argv"
kargo_run kargo-install.sh
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
assert_log_contains "pull oci://ghcr.io/akuity/kargo-charts/kargo --version 1.12.1 -d "
assert_log_contains "upgrade --install kargo /"
assert_log_contains "--values"
assert_log_contains "CONTENT passwordHash: '$KARGO_ADMIN_PASSWORD_HASH'"
assert_log_contains "CONTENT nodePort: 30090"
assert_not_in_argv "$KARGO_ADMIN_PASSWORD_HASH"
assert_not_in_argv "$KARGO_TOKEN_SIGNING_KEY"
assert_not_in_argv "$KARGO_ADMIN_PASSWORD"
assert_all_calls_pinned_to k3s-lab
values_path=$(sed -n 's/^HELM_VALUES_FILE //p' "$STUB_LOG")
if [ -n "$values_path" ] && [ ! -e "$values_path" ]; then ok; else fail "temporary values file was not removed ($values_path)"; fi

setup "kargo-install: tightens a pre-existing 0755 secrets dir"
kargo_run kargo-install.sh
chmod 755 "$SECRETS_DIR"
kargo_run kargo-install.sh
assert_rc 0
if [ "$(file_mode "$SECRETS_DIR")" = "700" ]; then ok; else fail "secrets dir left at $(file_mode "$SECRETS_DIR")"; fi

setup "kargo-install: local chart and cert-manager manifest overrides"
printf '        image: "quay.io/jetstack/cert-manager-controller:v1.21.3"\r\n' > "$WORK/case/cm.yaml"
printf 'local chart\n' > "$WORK/case/kargo-1.12.1.tgz"
run SCRIPTS="$(sha_pinned_scripts kargo-install.sh CHART_SHA256 "$WORK/case/kargo-1.12.1.tgz" \
  CERT_MANAGER_SHA256 "$WORK/case/cm.yaml")" \
  STUB_CERT_MANAGER_MISSING=1 KARGO_CHART="$WORK/case/kargo-1.12.1.tgz" CERT_MANAGER_MANIFEST="$WORK/case/cm.yaml" kargo-install.sh
assert_rc 0
assert_log_contains "upgrade --install kargo $WORK/case/kargo-1.12.1.tgz --namespace kargo"
assert_log_contains "apply --server-side --force-conflicts -f $WORK/case/cm.yaml"
assert_log_not_contains " pull "

setup "kargo-install: refuses a KARGO_CHART that isn't the pinned package"
printf 'another chart\n' > "$WORK/case/kargo-1.9.0.tgz"
kargo_run KARGO_CHART="$WORK/case/kargo-1.9.0.tgz" kargo-install.sh
assert_rc 1
assert_out_contains "not the pinned release, or modified"
assert_log_not_contains "upgrade --install"

setup "kargo-install: refuses a re-pushed chart tag (sha256 mismatch)"
run STUB_CHART_FILE="$KARGO_FAKE_CHART" kargo-install.sh
assert_rc 1
assert_out_contains "expected d152209bc01fe7577285ecc1803e4dac4832ec6e7a7724a89351dbf799d43d6a"
assert_log_not_contains "upgrade --install"

setup "kargo-install: a verified chart is cached for re-runs"
kargo_run kargo-install.sh
assert_rc 0
assert_log_contains " pull oci://ghcr.io/akuity/kargo-charts/kargo"
if cmp -s "$KARGO_FAKE_CHART" "$CACHE_DIR/kargo-1.12.1.tgz"; then ok; else fail "chart not cached"; fi
: > "$STUB_LOG"
kargo_run kargo-install.sh
assert_rc 0
assert_out_contains "Using the cached Kargo chart"
assert_log_not_contains " pull "
assert_log_contains "upgrade --install kargo $CACHE_DIR/kargo-1.12.1.tgz"

setup "kargo-install: a corrupted cached chart is pulled again"
mkdir -p "$CACHE_DIR"
printf 'corrupted\n' > "$CACHE_DIR/kargo-1.12.1.tgz"
kargo_run kargo-install.sh
assert_rc 0
assert_log_contains " pull oci://ghcr.io/akuity/kargo-charts/kargo"
if cmp -s "$KARGO_FAKE_CHART" "$CACHE_DIR/kargo-1.12.1.tgz"; then ok; else fail "corrupted cache not replaced"; fi

setup "kargo-install: a re-pushed chart is not cached"
run STUB_CHART_FILE="$KARGO_FAKE_CHART" kargo-install.sh
assert_rc 1
if [ ! -e "$CACHE_DIR/kargo-1.12.1.tgz" ]; then ok; else fail "unverified chart was cached"; fi

setup "kargo-install: an unpacked chart directory gets a clear error"
kargo_run KARGO_CHART="$WORK/case" kargo-install.sh
assert_rc 1
assert_out_contains "is a directory; give a packaged chart"
assert_out_not_contains "not the pinned release"

setup "kargo-install: a Helm repo chart reference is pulled at the pinned version"
kargo_run KARGO_CHART=mirror/kargo kargo-install.sh
assert_rc 0
assert_log_contains "pull mirror/kargo --version 1.12.1 -d "
assert_log_contains "upgrade --install kargo /"

setup "kargo-install: a failed cert-manager check is not mistaken for 'missing'"
kargo_run STUB_CERT_MANAGER_ERROR=1 kargo-install.sh
assert_rc 1
assert_out_contains "Could not check for an existing cert-manager"
assert_log_not_contains "apply --server-side"
assert_log_not_contains "curl "
assert_log_not_contains "upgrade --install"

setup "kargo-install: re-runs reuse the same credentials"
kargo_run kargo-install.sh
first=$(cat "$SECRETS_DIR/kargo-admin.env")
kargo_run kargo-install.sh
assert_rc 0
assert_out_contains "Reusing existing Kargo admin credentials"
if [ "$first" = "$(cat "$SECRETS_DIR/kargo-admin.env")" ]; then ok; else fail "credentials changed on re-run"; fi

setup "kargo-password: prints the stored password"
kargo_run kargo-install.sh
# shellcheck disable=SC1090,SC1091
. "$SECRETS_DIR/kargo-admin.env"
run kargo-password.sh
assert_rc 0
assert_out_contains "Kargo admin password: $KARGO_ADMIN_PASSWORD"

setup "kargo-password: a missing password is not taken from the environment"
mkdir -p "$SECRETS_DIR"
printf "KARGO_TOKEN_SIGNING_KEY=k\n" > "$SECRETS_DIR/kargo-admin.env"
run KARGO_ADMIN_PASSWORD=fromenv kargo-password.sh
assert_rc 1
assert_out_not_contains "fromenv"
assert_out_contains "KARGO_ADMIN_PASSWORD missing"

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
assert_log_contains "CONTENT secret redis-credentials redis.conf=requirepass $REDIS_PASSWORD|user hello-devops on >$APP_REDIS_PASSWORD ~* &* +@all -@admin -@dangerous|"
assert_log_contains "CONTENT secret hello-devops-db-credentials PGUSER=hello_devops"
assert_log_contains "CONTENT secret hello-devops-db-credentials PGPASSWORD=$APP_POSTGRES_PASSWORD"
assert_log_contains "CONTENT secret hello-devops-db-credentials MONGODB_URI=mongodb://hello-devops:$APP_MONGODB_PASSWORD@"
assert_log_contains "CONTENT secret hello-devops-db-credentials REDIS_PASSWORD=$APP_REDIS_PASSWORD"
assert_log_contains "create secret generic hello-devops-db-credentials -n hello-devops-dev"
assert_log_contains "create secret generic hello-devops-db-credentials -n hello-devops-staging"
assert_not_in_argv "$APP_POSTGRES_PASSWORD"
assert_not_in_argv "$APP_MONGODB_PASSWORD"
assert_not_in_argv "$APP_REDIS_PASSWORD"
if [ "$APP_POSTGRES_PASSWORD" != "$POSTGRES_PASSWORD" ]; then ok; else fail "app and superuser passwords are the same"; fi
assert_not_in_argv "$POSTGRES_PASSWORD"
assert_not_in_argv "$MONGODB_PASSWORD"
assert_not_in_argv "$REDIS_PASSWORD"
assert_log_contains "apply -k $REPO_ROOT/kubernetes/databases"
for app in postgres mongodb redis; do
  assert_log_contains "rollout status deploy/$app -n databases"
done
assert_all_calls_pinned_to k3s-lab
if [ "$POSTGRES_PASSWORD" != "$REDIS_PASSWORD" ]; then ok; else fail "passwords are not independent"; fi

setup "databases-install: ignores credentials exported in the caller's environment"
run POSTGRES_PASSWORD=fromenv REDIS_PASSWORD=fromenv APP_REDIS_PASSWORD=fromenv \
  MONGODB_USERNAME=fromenv databases-install.sh
assert_rc 0
if grep -q fromenv "$SECRETS_DIR/databases.env"; then fail "environment value used for a credential"; else ok; fi
for k in POSTGRES_PASSWORD MONGODB_USERNAME REDIS_PASSWORD APP_REDIS_PASSWORD; do
  if grep -q "^$k=." "$SECRETS_DIR/databases.env"; then ok; else fail "$k not saved to the credentials file"; fi
done
assert_log_not_contains "fromenv"

setup "databases-install: refuses hand-edited values with unsafe characters"
mkdir -p "$SECRETS_DIR"
printf 'POSTGRES_PASSWORD=pg\nAPP_MONGODB_PASSWORD=p@ss/1\n' > "$SECRETS_DIR/databases.env"
run databases-install.sh
assert_rc 1
assert_out_contains "line(s) 2 must be KEY=value"
assert_out_not_contains "p@ss"
assert_log_not_contains "create secret"

setup "databases-install: accepts quoted values in the credentials file"
mkdir -p "$SECRETS_DIR"
printf '%s\n' 'POSTGRES_PASSWORD="pg1"' "REDIS_PASSWORD='rd1'" > "$SECRETS_DIR/databases.env"
run databases-install.sh
assert_rc 0
assert_log_contains "CONTENT secret postgres-credentials password=pg1"
assert_log_contains "CONTENT secret redis-credentials password=rd1"

setup "databases-install: explains CRLF line endings"
mkdir -p "$SECRETS_DIR"
printf 'POSTGRES_PASSWORD=pg\r\n' > "$SECRETS_DIR/databases.env"
run databases-install.sh
assert_rc 1
assert_out_contains "Windows (CRLF) line endings"
assert_log_not_contains "create secret"

setup "databases-install: refuses to pair new passwords with existing volumes"
STUB_PVCS="persistentvolumeclaim/postgres-data"
run databases-install.sh
assert_rc 1
assert_out_contains "Existing database volumes found"
if [ ! -e "$SECRETS_DIR/databases.env" ]; then ok; else fail "unused credentials file left behind"; fi
assert_log_not_contains "apply -k"

setup "databases-install: an older credentials file gains the app keys, keeps its values"
mkdir -p "$SECRETS_DIR"
printf '%s\n' POSTGRES_PASSWORD=oldpg MONGODB_USERNAME=root MONGODB_PASSWORD=oldmongo REDIS_PASSWORD=oldredis \
  > "$SECRETS_DIR/databases.env"
chmod 755 "$SECRETS_DIR"
run databases-install.sh
assert_rc 0
# shellcheck disable=SC1090,SC1091
. "$SECRETS_DIR/databases.env"
if [ "$POSTGRES_PASSWORD/$MONGODB_PASSWORD/$REDIS_PASSWORD" = oldpg/oldmongo/oldredis ]; then ok
else fail "existing credentials were changed"; fi
if [ -n "$APP_POSTGRES_PASSWORD" ] && [ -n "$APP_MONGODB_PASSWORD" ] && [ -n "$APP_REDIS_PASSWORD" ]; then ok
else fail "app credentials were not added"; fi
if [ "$(file_mode "$SECRETS_DIR")" = "700" ]; then ok; else fail "secrets dir not tightened to 700"; fi
leftover=""
for f in "$SECRETS_DIR"/*.env.*; do [ -e "$f" ] && leftover="$f"; done
if [ -n "$leftover" ]; then fail "temporary credentials file left behind: $leftover"; else ok; fi

setup "databases-install: a credentials file without a final newline is extended safely"
mkdir -p "$SECRETS_DIR"
printf 'POSTGRES_PASSWORD=pg\nMONGODB_USERNAME=root\nMONGODB_PASSWORD=mo\nREDIS_PASSWORD=rd' > "$SECRETS_DIR/databases.env"
run databases-install.sh
assert_rc 0
# shellcheck disable=SC1090,SC1091
. "$SECRETS_DIR/databases.env"
if [ "$REDIS_PASSWORD" = rd ] && [ -n "${APP_POSTGRES_PASSWORD:-}" ]; then ok
else fail "last line corrupted: REDIS_PASSWORD='$REDIS_PASSWORD'"; fi

setup "databases-install: Redis restarted only when its existing config changed"
export STUB_APPLY_ACTION=created
run databases-install.sh
assert_log_not_contains "rollout restart deploy/redis"
export STUB_APPLY_ACTION=configured
: > "$STUB_LOG"
run databases-install.sh
assert_log_contains "rollout restart deploy/redis -n databases"
export STUB_APPLY_ACTION=unchanged
: > "$STUB_LOG"
run databases-install.sh
assert_log_not_contains "rollout restart deploy/redis"

setup "databases-install: re-runs the provisioning Job each time"
run databases-install.sh
assert_rc 0
assert_log_contains "delete job hello-devops-db-users -n databases --ignore-not-found"
assert_log_contains "CONTENT secret hello-devops-app-db postgres-password="
assert_log_contains "CONTENT secret hello-devops-app-db mongodb-password="
assert_out_contains "hello-devops database users are up to date."

setup "databases-install: a failed provisioning Job fails the install, with its logs"
export STUB_JOB_STATE=Failed
run databases-install.sh
assert_rc 1
assert_out_contains "Could not create/update the hello-devops database users."
assert_out_contains "MongoServerError: Authentication failed."
assert_log_not_contains "hello-devops-db-credentials"

setup "databases-install: app namespaces are overridable"
run DB_APP_NAMESPACES="ns-a" databases-install.sh
assert_rc 0
assert_log_contains "create secret generic hello-devops-db-credentials -n ns-a"
assert_log_not_contains "-n hello-devops-dev"

setup "databases-install: an API error listing volumes stops the install"
export STUB_PVC_RC=1
run databases-install.sh
assert_rc 1
assert_out_contains "Could not list PVCs"
assert_log_not_contains "apply -k"

setup "databases-install: existing volumes are fine when credentials exist"
run databases-install.sh
STUB_PVCS="persistentvolumeclaim/postgres-data
persistentvolumeclaim/mongodb-data"
: > "$STUB_LOG"
run databases-install.sh
assert_rc 0
assert_log_contains "apply -k"

setup "databases-status: shows the provisioning Job and flags a failed run"
run databases-status.sh
assert_rc 0
assert_out_contains "== App-user provisioning Job =="
assert_out_contains "hello-devops-db-users Complete"
assert_out_not_contains "Last run FAILED"
export STUB_JOB_STATE=Failed
run databases-status.sh
assert_out_contains "Last run FAILED"
export STUB_JOB_STATE=absent
run databases-status.sh
assert_rc 0
assert_out_contains "(no recent run"

setup "databases-password: prints all three credentials"
run databases-install.sh
# shellcheck disable=SC1090,SC1091
. "$SECRETS_DIR/databases.env"
run databases-password.sh
assert_rc 0
assert_out_contains "$POSTGRES_PASSWORD"
assert_out_contains "$MONGODB_PASSWORD"
assert_out_contains "$REDIS_PASSWORD"

setup "databases-password: a key missing from the file is not taken from the environment"
mkdir -p "$SECRETS_DIR"
printf 'POSTGRES_PASSWORD=pg\n' > "$SECRETS_DIR/databases.env"
run APP_REDIS_PASSWORD=fromenv databases-password.sh
assert_rc 0
assert_out_not_contains "fromenv"
assert_out_contains "user hello-devops, password ?"

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

setup "vm-status: reports a stopped VM without shelling into it"
STUB_VM_STATUS="Stopped"
run vm-status.sh
assert_rc 0
assert_out_contains "is Stopped. Run: make vm-start"
assert_log_not_contains "limactl shell"

setup "unpinned_calls: exact context match only"
printf '%s\n' "kubectl --context k3s-lab-old get nodes" "helm --kube-context k3s-lab list" \
  "kubectl --context k3s-lab get pods" > "$STUB_LOG"
if [ "$(unpinned_calls k3s-lab)" = "kubectl --context k3s-lab-old get nodes" ]; then ok
else fail "look-alike context not detected: '$(unpinned_calls k3s-lab)'"; fi
# Regex metacharacters in the context name are taken literally.
echo "kubectl --context k3sXlab get nodes" > "$STUB_LOG"
if [ -n "$(unpinned_calls k3s.lab)" ]; then ok; else fail "'.' in a context name matched any character"; fi

setup "k3s-start: installs the pinned K3s version when missing"
export STUB_K3S_INSTALLED=0
printf '#!/bin/sh\n' > "$WORK/case/install.sh"
run SCRIPTS="$(sha_pinned_scripts k3s-start.sh K3S_INSTALLER_SHA256 "$WORK/case/install.sh")" \
  STUB_CURL_FILE="$WORK/case/install.sh" k3s-start.sh
assert_rc 0
assert_log_contains "curl -fsSL --proto =https --proto-redir =https -o"
assert_log_contains "https://raw.githubusercontent.com/k3s-io/k3s/v1.36.5+k3s1/install.sh"
assert_log_not_contains "get.k3s.io"
assert_log_contains "v1.36.5+k3s1"
assert_log_contains "systemctl start k3s"

setup "k3s-start: refuses an installer that doesn't match the pinned sha256"
export STUB_K3S_INSTALLED=0
printf '#!/bin/sh\n' > "$WORK/case/install.sh"
run STUB_CURL_FILE="$WORK/case/install.sh" k3s-start.sh
assert_rc 1
assert_out_contains "expected 46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad"
assert_log_not_contains "INSTALL_K3S_FORCE_RESTART"
assert_log_not_contains "systemctl start k3s"

setup "k3s-status: reports an inactive service instead of crashing"
export STUB_K3S_ACTIVE=inactive
run k3s-status.sh
assert_rc 1
assert_out_contains "K3s is not running"

# --- summary ------------------------------------------------------------------

echo
echo "scripts_test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
