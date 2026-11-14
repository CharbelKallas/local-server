#!/bin/sh
# End-to-end test against a real (throwaway) Kubernetes cluster.
#
# Creates a kind cluster with its OWN kubeconfig file, so the real
# ~/.kube/config and the Lima/K3s lab are never touched. Then runs the real
# scripts against it and checks behaviour from the outside:
#
#   databases  make databases-install; each database rejects clients without
#              (or with wrong) credentials, accepts the generated ones, keeps
#              data across pod restarts, runs as non-root; re-run is a no-op.
#   argocd     make argocd-install (pinned version, NodePort 30080), the
#              AppProject + Applications are accepted by the real CRDs, and
#              the AppProject blocks deploying outside its namespaces.
#   kargo      make kargo-install (cert-manager + chart, NodePort 30090), the
#              admin password works against the API, and the Kargo manifests
#              are accepted by the real CRDs/webhooks.
#
# Needs: docker, kind, kubectl, helm, openssl, htpasswd.
# Env:   E2E_SKIP="argocd kargo"   skip suites
#        E2E_KEEP=1                keep the cluster afterwards (for debugging)
set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CLUSTER="local-server-e2e"
WORK=$(mktemp -d)

export KUBECONFIG="$WORK/kubeconfig"
export KUBE_CONTEXT="kind-$CLUSTER"
export SECRETS_DIR="$WORK/secrets"

cleanup() {
  rc=$?
  if [ "${E2E_KEEP:-0}" = 1 ]; then
    echo "Keeping cluster '$CLUSTER' (KUBECONFIG=$KUBECONFIG)."
  else
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
    rm -rf "$WORK"
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

skip() { case " ${E2E_SKIP:-} " in *" $1 "*) return 0 ;; esac; return 1; }
step() { printf '\n==> %s\n' "$*"; }
pass() { printf '    ok: %s\n' "$*"; }
fail() { printf '    FAIL: %s\n' "$*" >&2; exit 1; }
kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }

# Run a one-off client pod in the databases namespace; prints its logs and
# returns non-zero if the pod failed. Deliberately not `kubectl run -i --rm`:
# attaching to a short-lived pod races with its exit and can lose the output.
client() {
  name=$1 image=$2
  shift 2
  kc run "$name" -n databases --image="$image" --restart=Never --command -- "$@" >/dev/null
  phase=""
  for _ in $(seq 1 90); do
    phase=$(kc get pod "$name" -n databases -o jsonpath='{.status.phase}' 2>/dev/null || true)
    case "$phase" in Succeeded|Failed) break ;; esac
    sleep 2
  done
  kc logs "$name" -n databases 2>&1 || true
  kc delete pod "$name" -n databases --wait=false >/dev/null 2>&1 || true
  [ "$phase" = Succeeded ]
}

for c in docker kind kubectl helm openssl htpasswd; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required"
done

step "Creating kind cluster '$CLUSTER'"
kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
kind create cluster --name "$CLUSTER" --wait 120s
# K3s ships the local-path provisioner as StorageClass "local-path"; kind
# ships the same provisioner as "standard". Alias it so the manifests are
# used unmodified.
kc apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF

# ---------------------------------------------------------------------------
step "databases: make databases-install"
"$REPO_ROOT/scripts/databases-install.sh"
# shellcheck disable=SC1091
. "$SECRETS_DIR/databases.env"
if "$REPO_ROOT/scripts/databases-status.sh" >/dev/null; then pass "databases-status"; else fail "databases-status"; fi

step "databases: PostgreSQL authentication and data"
out=$(client pg-noauth postgres:17-alpine \
  psql -h postgres.databases.svc -U postgres -d lab -w -c 'select 1' || true)
case "$out" in
  *"password authentication failed"*|*"no password supplied"*) pass "rejects client without password" ;;
  *) fail "PostgreSQL accepted a client without a password: $out" ;;
esac
out=$(client pg-badpw postgres:17-alpine \
  env PGPASSWORD=wrong psql -h postgres.databases.svc -U postgres -d lab -c 'select 1' || true)
case "$out" in
  *"password authentication failed"*) pass "rejects wrong password" ;;
  *) fail "PostgreSQL accepted a wrong password: $out" ;;
esac
out=$(client pg-ok postgres:17-alpine env PGPASSWORD="$POSTGRES_PASSWORD" \
  psql -h postgres.databases.svc -U postgres -d lab -tAc \
  "create table if not exists e2e(v text); insert into e2e values ('persisted'); select v from e2e")
case "$out" in *persisted*) pass "accepts generated password, writes data" ;; *) fail "psql: $out" ;; esac

step "databases: MongoDB authentication and data"
out=$(client mongo-noauth mongo:8.0 \
  mongosh --quiet "mongodb://mongodb.databases.svc:27017/lab" --eval 'db.e2e.insertOne({v: 1})' || true)
case "$out" in
  *"requires authentication"*|*"Unauthorized"*) pass "rejects unauthenticated write" ;;
  *) fail "MongoDB accepted an unauthenticated write: $out" ;;
esac
out=$(client mongo-ok mongo:8.0 mongosh --quiet \
  "mongodb://$MONGODB_USERNAME:$MONGODB_PASSWORD@mongodb.databases.svc:27017/lab?authSource=admin" \
  --eval 'db.e2e.insertOne({v: "persisted"}); print(db.e2e.findOne().v)')
case "$out" in *persisted*) pass "accepts generated credentials, writes data" ;; *) fail "mongosh: $out" ;; esac

step "databases: Redis authentication and data"
out=$(client redis-noauth redis:7.4-alpine redis-cli -h redis.databases.svc set e2e x || true)
case "$out" in *NOAUTH*) pass "rejects client without password" ;; *) fail "Redis accepted a client without a password: $out" ;; esac
out=$(client redis-ok redis:7.4-alpine env REDISCLI_AUTH="$REDIS_PASSWORD" \
  sh -c 'redis-cli -h redis.databases.svc set e2e persisted >/dev/null && redis-cli -h redis.databases.svc get e2e')
case "$out" in *persisted*) pass "accepts generated password, writes data" ;; *) fail "redis-cli: $out" ;; esac

step "databases: run as non-root, password not in Redis argv"
for pair in postgres:70 mongodb:999 redis:999; do
  app=${pair%%:*} want=${pair#*:}
  uid=$(kc exec -n databases deploy/"$app" -- id -u | tr -d '\r')
  if [ "$uid" = "$want" ]; then pass "$app runs as uid $uid"; else fail "$app runs as uid $uid, expected $want"; fi
done
cmdline=$(kc exec -n databases deploy/redis -- cat /proc/1/cmdline | tr '\0' ' ')
case "$cmdline" in *"$REDIS_PASSWORD"*) fail "Redis password visible in process arguments" ;; *) pass "Redis argv has no password" ;; esac

step "databases: data survives pod restarts"
kc rollout restart deploy/postgres deploy/mongodb deploy/redis -n databases >/dev/null
for app in postgres mongodb redis; do kc rollout status deploy/"$app" -n databases --timeout=300s >/dev/null; done
out=$(client pg-after postgres:17-alpine env PGPASSWORD="$POSTGRES_PASSWORD" \
  psql -h postgres.databases.svc -U postgres -d lab -tAc 'select v from e2e')
case "$out" in *persisted*) pass "PostgreSQL data persisted" ;; *) fail "PostgreSQL lost data: $out" ;; esac
out=$(client mongo-after mongo:8.0 mongosh --quiet \
  "mongodb://$MONGODB_USERNAME:$MONGODB_PASSWORD@mongodb.databases.svc:27017/lab?authSource=admin" \
  --eval 'print(db.e2e.findOne().v)')
case "$out" in *persisted*) pass "MongoDB data persisted" ;; *) fail "MongoDB lost data: $out" ;; esac
out=$(client redis-after redis:7.4-alpine env REDISCLI_AUTH="$REDIS_PASSWORD" \
  redis-cli -h redis.databases.svc get e2e)
case "$out" in *persisted*) pass "Redis data persisted (AOF)" ;; *) fail "Redis lost data: $out" ;; esac

step "databases: re-running install is idempotent"
before=$(cat "$SECRETS_DIR/databases.env")
"$REPO_ROOT/scripts/databases-install.sh" >/dev/null
if [ "$before" = "$(cat "$SECRETS_DIR/databases.env")" ]; then pass "credentials unchanged"; else fail "credentials changed"; fi
out=$(client pg-rerun postgres:17-alpine env PGPASSWORD="$POSTGRES_PASSWORD" \
  psql -h postgres.databases.svc -U postgres -d lab -tAc 'select v from e2e')
case "$out" in *persisted*) pass "still reachable with same password" ;; *) fail "after re-run: $out" ;; esac

# ---------------------------------------------------------------------------
if skip argocd; then
  step "argocd: skipped"
else
  step "argocd: make argocd-install"
  "$REPO_ROOT/scripts/argocd-install.sh"
  if [ "$(kc get svc argocd-server -n argocd -o jsonpath='{.spec.type}')" = NodePort ]; then pass "argocd-server is a NodePort"; else fail "argocd-server is a NodePort"; fi
  if "$REPO_ROOT/scripts/argocd-install.sh" >/dev/null; then pass "re-run is idempotent"; else fail "re-run is idempotent"; fi
  if "$REPO_ROOT/scripts/argocd-password.sh" | grep -q 'Initial admin password: .'; then pass "argocd-password"; else fail "argocd-password"; fi
  if "$REPO_ROOT/scripts/argocd-status.sh" | grep -q 'https://localhost:30080'; then pass "argocd-status shows UI address"; else fail "argocd-status shows UI address"; fi

  step "argocd: GitOps manifests against the real CRDs"
  kc apply -f "$REPO_ROOT/kubernetes/argocd/projects/hello-devops.yaml"
  if kc apply --dry-run=server -f "$REPO_ROOT/kubernetes/argocd/applications/" >/dev/null; then
    pass "Applications accepted by the API server"
  else fail "Applications rejected by the API server"; fi

  step "argocd: AppProject blocks deploying outside its namespaces"
  kc apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: e2e-escape-attempt
  namespace: argocd
spec:
  project: hello-devops
  source:
    repoURL: https://github.com/CharbelKallas/hello-devops.git
    targetRevision: master
    path: dev
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
EOF
  msg=""
  for _ in $(seq 1 60); do
    msg=$(kc get application e2e-escape-attempt -n argocd \
      -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' 2>/dev/null || true)
    [ -n "$msg" ] && break
    sleep 2
  done
  case "$msg" in
    # Wording differs between Argo CD versions ("not permitted" /
    # "do not match any of the allowed destinations").
    *InvalidSpecError*kube-system*) pass "kube-system destination rejected by the project" ;;
    *) fail "AppProject did not reject kube-system destination: '$msg'" ;;
  esac
  kc delete application e2e-escape-attempt -n argocd --wait=false >/dev/null
fi

# ---------------------------------------------------------------------------
if skip kargo; then
  step "kargo: skipped"
else
  step "kargo: make kargo-install"
  "$REPO_ROOT/scripts/kargo-install.sh"
  if "$REPO_ROOT/scripts/kargo-install.sh" >/dev/null; then pass "re-run is idempotent"; else fail "re-run is idempotent"; fi
  if "$REPO_ROOT/scripts/kargo-status.sh" | grep -q 'https://localhost:30090'; then pass "kargo-status shows UI address"; else fail "kargo-status shows UI address"; fi

  step "kargo: admin password works against the API"
  # shellcheck disable=SC1091
  . "$SECRETS_DIR/kargo-admin.env"
  kc port-forward -n kargo svc/kargo-api 39443:443 >/dev/null 2>&1 &
  pf=$!
  sleep 3
  # Kargo >= 1.12 REST API: POST /v1beta1/login, "Authorization: Bearer
  # <password>" (pkg/server/admin_login.go). The header is read from a file
  # so the password is not on curl's command line.
  login() {
    printf 'Authorization: Bearer %s\n' "$1" > "$WORK/auth-header"
    curl -sk -o /dev/null -w '%{http_code}' -X POST -H @"$WORK/auth-header" \
      https://127.0.0.1:39443/v1beta1/login
    rm -f "$WORK/auth-header"
  }
  good=$(login "$KARGO_ADMIN_PASSWORD")
  bad=$(login "not-the-password")
  kill "$pf" 2>/dev/null || true
  if [ "$good" = 200 ]; then pass "admin login with stored password"; else fail "admin login returned HTTP $good"; fi
  if [ "$bad" != 200 ]; then pass "wrong password rejected (HTTP $bad)"; else fail "wrong password accepted"; fi

  step "kargo: GitOps manifests against the real CRDs and webhooks"
  kc apply -f "$REPO_ROOT/kubernetes/kargo/project.yaml"
  for _ in $(seq 1 30); do kc get ns hello-devops >/dev/null 2>&1 && break; sleep 2; done
  # The registry placeholder is not a valid image reference; substitute a
  # sample value for validation only.
  for f in warehouse stage-dev stage-staging; do
    sed 's|<LOCAL_REGISTRY_URL>|localhost:5000|g' "$REPO_ROOT/kubernetes/kargo/$f.yaml" \
      | kc apply --dry-run=server -f - >/dev/null
    pass "$f accepted by the API server"
  done
fi

printf '\nE2E: all checks passed.\n'
