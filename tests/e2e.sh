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

# The hello-devops Applications track the app repo's master branch. The
# test pins them to a known commit so this repo's CI only changes when this
# repo does; bump deliberately after checking the app still meets the
# AppProject and Pod Security rules.
HELLO_DEVOPS_REV="f293f25e1bfa2f4b1e3932d8d30ee43b8bd5b466"
PF_PID=""

cleanup() {
  rc=$?
  [ -z "$PF_PID" ] || kill "$PF_PID" 2>/dev/null || true
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
# kc() (kubectl pinned to $KUBE_CONTEXT) comes from the scripts' own library,
# so the harness talks to the cluster exactly like the scripts under test.
# shellcheck source=../scripts/lib.sh
. "$REPO_ROOT/scripts/lib.sh"

# Database clients: one long-lived pod per client image in namespace
# e2e-clients (clients connect across namespaces, like hello-devops does;
# the databases namespace enforces the "restricted" Pod Security profile,
# which these stock client images don't meet). Each check is a
# `kubectl exec` into the matching pod instead of a fresh pod per check.
client_pod() {
  case "$1" in
    postgres*) echo cli-postgres ;;
    mongo*) echo cli-mongo ;;
    redis*) echo cli-redis ;;
    *) fail "no client pod for image $1" ;;
  esac
}
start_clients() {
  kc create namespace e2e-clients >/dev/null
  for image in postgres:17-alpine mongo:8.0 redis:7.4-alpine; do
    kc run "$(client_pod "$image")" -n e2e-clients --image="$image" --restart=Never \
      --command -- sleep infinity >/dev/null
  done
  kc wait --for=condition=Ready pod --all -n e2e-clients --timeout=300s >/dev/null
}
# client <label> <image> <command...>: prints the command's output. Always
# succeeds: callers match on the output, so a failing command reaches their
# FAIL message (with this output) instead of tripping set -e.
client() {
  label=$1 image=$2
  shift 2
  kc exec -n e2e-clients "$(client_pod "$image")" -- "$@" 2>&1 \
    || echo "(client command '$label' exited non-zero)"
}

# expect_psa_rejected <namespace> <pod name> <--overrides JSON>
expect_psa_rejected() {
  out=$(kc run "$2" -n "$1" --image=busybox:1.36 --restart=Never --overrides="$3" 2>&1 || true)
  case "$out" in
    *"violates PodSecurity"*) pass "privileged pod '$2' rejected in $1" ;;
    *) kc delete pod "$2" -n "$1" --wait=false >/dev/null 2>&1 || true
       fail "privileged pod '$2' was admitted in $1: $out" ;;
  esac
}

# Apply an Application manifest pinned to $HELLO_DEVOPS_REV.
apply_pinned() {
  sed "s|targetRevision: master|targetRevision: $HELLO_DEVOPS_REV|" "$@" | kc apply -f - >/dev/null
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

# Side-load images from the host's Docker (pulled once, cached across runs)
# so the suite doesn't hinge on registry pulls from inside the kind node,
# which can crawl. Only the host platform is exported: Docker's containerd
# image store omits other platforms' layers, which breaks
# `kind load docker-image` (it imports --all-platforms). Best effort: if an
# image can't be preloaded, the node pulls it itself.
preload() {
  platform="linux/$(docker version --format '{{.Server.Arch}}')"
  for image in "$@"; do
    # Always pull: floating tags (mongo:8.0, ...) must match what CI and
    # the lab get, not a weeks-old local copy. Up to date = a cheap manifest
    # check. If the registry is unreachable, a cached copy is still used.
    docker pull -q --platform "$platform" "$image" >/dev/null 2>&1 || true
    if ! docker image inspect "$image" >/dev/null 2>&1; then
      printf '    note: could not pull %s; the node will pull it\n' "$image"
      continue
    fi
    # `docker save --platform` needs Docker 28+; older daemons (classic image
    # store, which has no multi-platform gap anyway) use a plain save.
    if docker save --platform "$platform" "$image" >"$WORK/image.tar" 2>/dev/null \
       || docker save "$image" >"$WORK/image.tar" 2>/dev/null; then
      if docker exec -i "$CLUSTER-control-plane" \
           ctr -n k8s.io images import --digests --snapshotter=overlayfs - \
           <"$WORK/image.tar" >/dev/null 2>&1; then
        printf '    preloaded %s\n' "$image"
      else
        printf '    note: could not import %s; the node will pull it\n' "$image"
      fi
    else
      printf '    note: could not export %s; the node will pull it\n' "$image"
    fi
    rm -f "$WORK/image.tar"
  done
}
# Image list of a rendered manifest (stdin).
images_in() { grep -oE 'image: *"?[^" ]+' | sed -E 's/image: *"?//' | sort -u; }
# Pinned versions, read from the install scripts (single source of truth).
pinned() { sed -n "s/^$1=\"\${$1:-\(.*\)}\".*/\1/p; s/^$1=\"\([^$]*\)\".*/\1/p" "$REPO_ROOT/scripts/$2" | head -n 1; }

step "Preloading database and client images into the kind node"
preload postgres:17-alpine mongo:8.0 redis:7.4-alpine busybox:1.36

# ---------------------------------------------------------------------------
step "databases: make databases-install"
"$REPO_ROOT/scripts/databases-install.sh"
start_clients
# shellcheck disable=SC1091
. "$SECRETS_DIR/databases.env"
if "$REPO_ROOT/scripts/databases-status.sh" >/dev/null; then pass "databases-status"; else fail "databases-status"; fi

step "databases: PostgreSQL authentication and data"
out=$(client pg-noauth postgres:17-alpine \
  psql -h postgres.databases.svc -U postgres -d lab -w -c 'select 1')
case "$out" in
  *"password authentication failed"*|*"no password supplied"*) pass "rejects client without password" ;;
  *) fail "PostgreSQL accepted a client without a password: $out" ;;
esac
out=$(client pg-badpw postgres:17-alpine \
  env PGPASSWORD=wrong psql -h postgres.databases.svc -U postgres -d lab -c 'select 1')
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
  mongosh --quiet "mongodb://mongodb.databases.svc:27017/lab" --eval 'db.e2e.insertOne({v: 1})')
case "$out" in
  *"requires authentication"*|*"Unauthorized"*) pass "rejects unauthenticated write" ;;
  *) fail "MongoDB accepted an unauthenticated write: $out" ;;
esac
out=$(client mongo-ok mongo:8.0 mongosh --quiet \
  "mongodb://$MONGODB_USERNAME:$MONGODB_PASSWORD@mongodb.databases.svc:27017/lab?authSource=admin" \
  --eval 'db.e2e.insertOne({v: "persisted"}); print(db.e2e.findOne().v)')
case "$out" in *persisted*) pass "accepts generated credentials, writes data" ;; *) fail "mongosh: $out" ;; esac

step "databases: Redis authentication and data"
out=$(client redis-noauth redis:7.4-alpine redis-cli -h redis.databases.svc set e2e x)
case "$out" in *NOAUTH*) pass "rejects client without password" ;; *) fail "Redis accepted a client without a password: $out" ;; esac
out=$(client redis-ok redis:7.4-alpine env REDISCLI_AUTH="$REDIS_PASSWORD" \
  sh -c 'redis-cli -h redis.databases.svc set e2e persisted >/dev/null && redis-cli -h redis.databases.svc get e2e')
case "$out" in *persisted*) pass "accepts generated password, writes data" ;; *) fail "redis-cli: $out" ;; esac

step "databases: hello-devops users are least-privilege"
# PostgreSQL: may create/use tables in lab, but not administer the server.
out=$(client pg-app postgres:17-alpine env PGPASSWORD="$APP_POSTGRES_PASSWORD" \
  psql -h postgres.databases.svc -U hello_devops -d lab -tAc \
  "create table app_e2e(v text); insert into app_e2e values ('app-ok'); select v from app_e2e")
case "$out" in *app-ok*) pass "PostgreSQL app user can use its database" ;; *) fail "PostgreSQL app user: $out" ;; esac
out=$(client pg-app-admin postgres:17-alpine env PGPASSWORD="$APP_POSTGRES_PASSWORD" \
  psql -h postgres.databases.svc -U hello_devops -d lab -c 'create role e2e_escalate superuser')
case "$out" in *"permission denied"*) pass "PostgreSQL app user cannot create roles" ;; *) fail "PostgreSQL app user created a role: $out" ;; esac
out=$(client pg-app-authid postgres:17-alpine env PGPASSWORD="$APP_POSTGRES_PASSWORD" \
  psql -h postgres.databases.svc -U hello_devops -d lab -c 'select rolpassword from pg_authid')
case "$out" in *"permission denied"*) pass "PostgreSQL app user cannot read password hashes" ;; *) fail "PostgreSQL app user read pg_authid: $out" ;; esac
out=$(client pg-app-otherdb postgres:17-alpine env PGPASSWORD="$APP_POSTGRES_PASSWORD" \
  psql -h postgres.databases.svc -U hello_devops -d postgres -c 'select 1')
case "$out" in *"permission denied for database"*) pass "PostgreSQL app user cannot connect to other databases" ;; *) fail "PostgreSQL app user connected to 'postgres': $out" ;; esac
out=$(client pg-app-temp postgres:17-alpine env PGPASSWORD="$APP_POSTGRES_PASSWORD" \
  psql -h postgres.databases.svc -U hello_devops -d lab -tAc \
  "create temp table t_e2e(v text); insert into t_e2e values ('temp-ok'); select v from t_e2e")
case "$out" in *temp-ok*) pass "PostgreSQL app user can use temporary tables in lab" ;; *) fail "PostgreSQL app user temp tables: $out" ;; esac
# MongoDB: readWrite on hello-devops only.
APP_MONGO="mongodb://hello-devops:$APP_MONGODB_PASSWORD@mongodb.databases.svc:27017/hello-devops?authSource=hello-devops"
out=$(client mongo-app mongo:8.0 mongosh --quiet "$APP_MONGO" \
  --eval 'db.e2e.insertOne({v: "app-ok"}); print(db.e2e.findOne({v: "app-ok"}).v)')
case "$out" in *app-ok*) pass "MongoDB app user can use its database" ;; *) fail "MongoDB app user: $out" ;; esac
out=$(client mongo-app-other mongo:8.0 mongosh --quiet "$APP_MONGO" \
  --eval 'db.getSiblingDB("lab").e2e.insertOne({v: 1})')
case "$out" in *"not authorized"*|*Unauthorized*) pass "MongoDB app user cannot write other databases" ;; *) fail "MongoDB app user wrote another database: $out" ;; esac
# Redis: data commands yes; admin/dangerous commands no.
out=$(client redis-app redis:7.4-alpine env REDISCLI_AUTH="$APP_REDIS_PASSWORD" \
  sh -c 'redis-cli -h redis.databases.svc --user hello-devops set app-e2e app-ok >/dev/null && redis-cli -h redis.databases.svc --user hello-devops get app-e2e')
case "$out" in *app-ok*) pass "Redis app user can read and write keys" ;; *) fail "Redis app user: $out" ;; esac
for cmd in "config get requirepass" "flushall" "acl list"; do
  # shellcheck disable=SC2086  # $cmd is deliberately split into words
  out=$(client redis-app-admin redis:7.4-alpine env REDISCLI_AUTH="$APP_REDIS_PASSWORD" \
    redis-cli -h redis.databases.svc --user hello-devops $cmd)
  case "$out" in *NOPERM*) pass "Redis app user denied: $cmd" ;; *) fail "Redis app user ran '$cmd': $out" ;; esac
done

step "databases: app credentials published into app namespaces"
# Throwaway namespace via DB_APP_NAMESPACES, so this runs without Argo CD.
kc create namespace e2e-app >/dev/null
DB_APP_NAMESPACES="e2e-app absent-ns" "$REPO_ROOT/scripts/databases-install.sh" > "$WORK/publish.log"
for key in PGUSER PGPASSWORD MONGODB_URI REDIS_USERNAME REDIS_PASSWORD; do
  if kc get secret hello-devops-db-credentials -n e2e-app -o jsonpath="{.data.$key}" | grep -q .; then
    pass "hello-devops-db-credentials has $key"
  else fail "hello-devops-db-credentials lacks $key"; fi
done
uri=$(kc get secret hello-devops-db-credentials -n e2e-app -o jsonpath='{.data.MONGODB_URI}' | base64 -d)
out=$(client mongo-published mongo:8.0 mongosh --quiet "$uri" --eval 'print(db.e2e.findOne({v: "app-ok"}).v)')
case "$out" in *app-ok*) pass "published MONGODB_URI works" ;; *) fail "published MONGODB_URI: $out" ;; esac
if grep -q "Namespace 'absent-ns' not found" "$WORK/publish.log"; then pass "absent namespace skipped with a message"
else fail "absent namespace not reported: $(cat "$WORK/publish.log")"; fi

step "databases: run as non-root, password not in Redis argv"
for pair in postgres:70 mongodb:999 redis:999; do
  app=${pair%%:*} want=${pair#*:}
  uid=$(kc exec -n databases deploy/"$app" -- id -u | tr -d '\r')
  if [ "$uid" = "$want" ]; then pass "$app runs as uid $uid"; else fail "$app runs as uid $uid, expected $want"; fi
done
cmdline=$(kc exec -n databases deploy/redis -- cat /proc/1/cmdline | tr '\0' ' ')
case "$cmdline" in *"$REDIS_PASSWORD"*) fail "Redis password visible in process arguments" ;; *) pass "Redis argv has no password" ;; esac

step "databases: namespace enforces the restricted Pod Security profile"
expect_psa_rejected databases e2e-privileged \
  '{"spec":{"containers":[{"name":"e2e-privileged","image":"busybox:1.36","command":["sleep","5"],"securityContext":{"privileged":true}}]}}'

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

step "databases: app users re-provisioned without the script (plain kubectl)"
# The documented no-script path: change the app password in the Secret,
# delete the finished Job, `kubectl apply -k` — the Job re-runs and applies it.
# Checked on the manifest itself: the live Job may already have been
# removed by its own TTL on a slow run.
ttl=$(kc apply --dry-run=client -f "$REPO_ROOT/kubernetes/databases/app-users-job.yaml" \
  -o jsonpath='{.spec.ttlSecondsAfterFinished}')
hook=$(kc apply --dry-run=client -f "$REPO_ROOT/kubernetes/databases/app-users-job.yaml" \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/hook}')
if [ "$ttl" = 600 ] && [ "$hook" = PostSync ]; then pass "Job has ttlSecondsAfterFinished=600 and a PostSync hook"
else fail "Job ttl='$ttl' hook='$hook'"; fi
# Includes a quote and a $(...): the Job must pass it to Postgres verbatim
# (a value from a secret manager is not limited to [A-Za-z0-9]).
rotated="$(gen_secret 24)'q\$(x)"
kc patch secret hello-devops-app-db -n databases --type=merge \
  -p "{\"stringData\":{\"postgres-password\":\"$rotated\"}}" >/dev/null
kc delete job hello-devops-db-users -n databases --ignore-not-found --wait=true >/dev/null
kc apply -k "$REPO_ROOT/kubernetes/databases" >/dev/null
if kc wait --for=condition=complete job/hello-devops-db-users -n databases --timeout=300s >/dev/null; then
  pass "Job re-ran after plain kubectl apply -k"
else fail "Job did not complete: $(kc logs job/hello-devops-db-users -n databases --all-containers --tail=10 2>&1)"; fi
out=$(client pg-rotated postgres:17-alpine env PGPASSWORD="$rotated" \
  psql -h postgres.databases.svc -U hello_devops -d lab -tAc "select 'rotated-ok'")
case "$out" in *rotated-ok*) pass "rotated app password (with quote and \$) is in effect" ;; *) fail "rotated password rejected: $out" ;; esac
# Restore the script-managed password for the remaining checks.
"$REPO_ROOT/scripts/databases-install.sh" >/dev/null
out=$(client pg-restored postgres:17-alpine env PGPASSWORD="$APP_POSTGRES_PASSWORD" \
  psql -h postgres.databases.svc -U hello_devops -d lab -tAc "select 'restored-ok'")
case "$out" in *restored-ok*) pass "install restores the managed app password" ;; *) fail "after restore: $out" ;; esac

# ---------------------------------------------------------------------------
if skip argocd; then
  step "argocd: skipped"
else
  step "argocd: preloading Argo CD images"
  # Downloaded once: the image list comes from it, and argocd-install.sh
  # applies this same file (ARGOCD_MANIFEST) instead of fetching it again.
  curl -fsSL -o "$WORK/argocd-install.yaml" \
    "https://raw.githubusercontent.com/argoproj/argo-cd/$(pinned ARGOCD_VERSION argocd-install.sh)/manifests/install.yaml"
  export ARGOCD_MANIFEST="$WORK/argocd-install.yaml"
  # shellcheck disable=SC2046  # one image per word
  preload $(images_in < "$ARGOCD_MANIFEST")

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
  kc apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: e2e-escape-attempt
  namespace: argocd
spec:
  project: hello-devops
  source:
    repoURL: https://github.com/CharbelKallas/hello-devops.git
    targetRevision: $HELLO_DEVOPS_REV
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

  step "argocd: AppProject refuses Namespace objects (no namespace takeover)"
  # Before the infra-owned namespaces exist, ask Argo CD to create one via
  # CreateNamespace=true: the project must refuse to deploy a Namespace.
  kc apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: e2e-namespace-attempt
  namespace: argocd
spec:
  project: hello-devops
  source:
    repoURL: https://github.com/CharbelKallas/hello-devops.git
    targetRevision: $HELLO_DEVOPS_REV
    path: dev
  destination:
    server: https://kubernetes.default.svc
    namespace: hello-devops-dev
  syncPolicy:
    automated: {}
    syncOptions:
      - CreateNamespace=true
EOF
  msg=""
  for _ in $(seq 1 60); do
    msg=$(kc get application e2e-namespace-attempt -n argocd \
      -o jsonpath='{.status.operationState.message}' 2>/dev/null || true)
    case "$msg" in *"Namespace is not permitted"*) break ;; esac
    sleep 2
  done
  case "$msg" in
    *"Namespace is not permitted"*) pass "Namespace object refused by the project" ;;
    *) fail "project did not refuse a Namespace object: '$msg'" ;;
  esac
  kc delete application e2e-namespace-attempt -n argocd --wait=true --timeout=120s >/dev/null
  if kc get ns hello-devops-dev >/dev/null 2>&1; then
    fail "namespace was created despite the project restriction"
  else pass "no namespace was created"; fi

  step "argocd: real Application syncs into infra-owned namespaces"
  kc apply -f "$REPO_ROOT/kubernetes/argocd/projects/hello-devops-namespaces.yaml" >/dev/null
  apply_pinned "$REPO_ROOT/kubernetes/argocd/applications/hello-devops-dev.yaml"
  synced=""
  for _ in $(seq 1 90); do
    synced=$(kc get application hello-devops-dev -n argocd \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    [ "$synced" = Synced ] && break
    sleep 2
  done
  if [ "$synced" = Synced ]; then pass "hello-devops-dev synced from the app repo"
  else fail "hello-devops-dev not synced (status '$synced'): $(kc get application hello-devops-dev -n argocd \
    -o jsonpath='{.status.operationState.message}' 2>/dev/null)"; fi
  if kc get deploy hello-devops -n hello-devops-dev >/dev/null 2>&1; then
    pass "app resources deployed into hello-devops-dev"
  else fail "app Deployment missing in hello-devops-dev"; fi

  step "argocd: app namespaces enforce the restricted Pod Security profile"
  # The real app's pods must be ADMITTED (they may not start: the image is
  # still a registry placeholder) ...
  pods=""
  for _ in $(seq 1 30); do
    pods=$(kc get pods -n hello-devops-dev -l app.kubernetes.io/name=hello-devops -o name 2>/dev/null)
    [ -n "$pods" ] && break
    sleep 2
  done
  if [ -n "$pods" ]; then pass "hello-devops pods admitted under 'restricted'"
  else fail "hello-devops pods not created: $(kc get rs -n hello-devops-dev \
    -o jsonpath='{.items[*].status.conditions[*].message}' 2>/dev/null)"; fi
  # ... while a privileged pod with a host mount (node escape) is refused.
  expect_psa_rejected hello-devops-dev e2e-escape \
    '{"spec":{"containers":[{"name":"e2e-escape","image":"busybox:1.36","command":["sleep","5"],"securityContext":{"privileged":true},"volumeMounts":[{"name":"host","mountPath":"/host"}]}],"volumes":[{"name":"host","hostPath":{"path":"/"}}]}}'

  step "databases: app credentials published into the app namespaces"
  "$REPO_ROOT/scripts/databases-install.sh" >/dev/null
  for ns in hello-devops-dev hello-devops-staging; do
    user=$(kc get secret hello-devops-db-credentials -n "$ns" -o jsonpath='{.data.PGUSER}' 2>/dev/null | base64 -d)
    if [ "$user" = hello_devops ]; then pass "hello-devops-db-credentials present in $ns"
    else fail "hello-devops-db-credentials missing or wrong in $ns ('$user')"; fi
  done
  kc delete application hello-devops-dev -n argocd --wait=false >/dev/null
fi

# ---------------------------------------------------------------------------
if skip kargo; then
  step "kargo: skipped"
else
  step "kargo: preloading cert-manager and Kargo images"
  # Downloaded once and handed to kargo-install.sh (CERT_MANAGER_MANIFEST,
  # KARGO_CHART), which then installs from these exact files.
  curl -fsSL -o "$WORK/cert-manager.yaml" \
    "https://github.com/cert-manager/cert-manager/releases/download/$(pinned CERT_MANAGER_VERSION kargo-install.sh)/cert-manager.yaml"
  export CERT_MANAGER_MANIFEST="$WORK/cert-manager.yaml"
  helm pull oci://ghcr.io/akuity/kargo-charts/kargo \
    --version "$(pinned CHART_VERSION kargo-install.sh)" -d "$WORK" >/dev/null
  KARGO_CHART=$(ls "$WORK"/kargo-*.tgz)
  export KARGO_CHART
  # shellcheck disable=SC2046  # one image per word
  preload $(images_in < "$CERT_MANAGER_MANIFEST")
  # The chart refuses to render without its mandatory admin values; dummies
  # are fine for listing images.
  # shellcheck disable=SC2046
  preload $(helm template kargo "$KARGO_CHART" \
    --set api.adminAccount.passwordHash=x --set api.adminAccount.tokenSigningKey=x 2>/dev/null | images_in)

  step "kargo: make kargo-install"
  "$REPO_ROOT/scripts/kargo-install.sh"
  if "$REPO_ROOT/scripts/kargo-install.sh" >/dev/null; then pass "re-run is idempotent"; else fail "re-run is idempotent"; fi
  if "$REPO_ROOT/scripts/kargo-status.sh" | grep -q 'https://localhost:30090'; then pass "kargo-status shows UI address"; else fail "kargo-status shows UI address"; fi

  step "kargo: admin password works against the API"
  # shellcheck disable=SC1091
  . "$SECRETS_DIR/kargo-admin.env"
  # Local port 0 = let kubectl pick a free port; read it from its output
  # and wait until the tunnel is actually up (no fixed port, no blind sleep).
  kc port-forward -n kargo svc/kargo-api :443 > "$WORK/port-forward.log" 2>&1 &
  PF_PID=$!
  port=""
  for _ in $(seq 1 30); do
    port=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$WORK/port-forward.log" | head -n 1)
    [ -n "$port" ] && break
    kill -0 "$PF_PID" 2>/dev/null || fail "port-forward to kargo-api died: $(cat "$WORK/port-forward.log")"
    sleep 1
  done
  [ -n "$port" ] || fail "port-forward to kargo-api did not come up: $(cat "$WORK/port-forward.log")"
  # Kargo >= 1.12 REST API: POST /v1beta1/login, "Authorization: Bearer
  # <password>" (pkg/server/admin_login.go). The header is read from a file
  # so the password is not on curl's command line.
  login() {
    printf 'Authorization: Bearer %s\n' "$1" > "$WORK/auth-header"
    curl -sk -o /dev/null -w '%{http_code}' -X POST -H @"$WORK/auth-header" \
      "https://127.0.0.1:$port/v1beta1/login"
    rm -f "$WORK/auth-header"
  }
  good=$(login "$KARGO_ADMIN_PASSWORD")
  bad=$(login "not-the-password")
  kill "$PF_PID" 2>/dev/null || true
  PF_PID=""
  if [ "$good" = 200 ]; then pass "admin login with stored password"; else fail "admin login returned HTTP $good"; fi
  if [ "$bad" != 200 ]; then pass "wrong password rejected (HTTP $bad)"; else fail "wrong password accepted"; fi

  step "kargo: GitOps manifests against the real CRDs and webhooks"
  kc apply -f "$REPO_ROOT/kubernetes/kargo/project.yaml"
  for _ in $(seq 1 30); do kc get ns hello-devops >/dev/null 2>&1 && break; sleep 2; done
  kc get ns hello-devops >/dev/null 2>&1 \
    || fail "Kargo did not create namespace 'hello-devops' for Project hello-devops within 60s"
  # The registry placeholder is not a valid image reference; substitute a
  # sample value for validation only.
  for f in warehouse stage-dev stage-staging; do
    sed 's|<LOCAL_REGISTRY_URL>|localhost:5000|g' "$REPO_ROOT/kubernetes/kargo/$f.yaml" \
      | kc apply --dry-run=server -f - >/dev/null
    pass "$f accepted by the API server"
  done
fi

printf '\nE2E: all checks passed.\n'
