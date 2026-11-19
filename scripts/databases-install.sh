#!/bin/sh
# Deploy PostgreSQL, MongoDB and Redis into the K3s cluster (namespace
# "databases") with password authentication, plus least-privilege
# application users for hello-devops.
#
# 1. Generates credentials once into secrets/databases.env (gitignored,
#    mode 600) and reuses them on re-runs. Keys missing from an older file
#    are added; existing values are never changed.
# 2. Creates/updates the database credential Secrets. Values are passed to
#    kubectl through private temp files, never on the command line.
# 3. Applies kubernetes/databases/ (kustomize) and waits for the rollouts.
# 4. Re-runs the Job that creates/updates the hello-devops users — they can
#    use only their own database, never administer the server — and
#    publishes their credentials as Secret "hello-devops-db-credentials" in
#    each hello-devops namespace that exists.
#
# Idempotent: safe to re-run.
set -eu
. "$(dirname -- "$0")/lib.sh"

NAMESPACE="databases"
CRED_FILE="$SECRETS_DIR/databases.env"
APP_NAMESPACES="${DB_APP_NAMESPACES:-hello-devops-dev hello-devops-staging}"
APP_SECRET="hello-devops-db-credentials"
USERS_JOB="hello-devops-db-users"

require_cluster
require_cmd openssl

# Temp files hold real passwords: always remove them, even on Ctrl-C.
umask 077
tmp_cred=""
work=""
cleanup() { rm -f "$tmp_cred"; [ -z "$work" ] || rm -rf "$work"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- credentials (generated once, reused on re-runs) -----------------------
ensure_secrets_dir
clear_db_credentials
fresh_credentials=true
tmp_cred=$(mktemp "$CRED_FILE.XXXXXX")
if [ -f "$CRED_FILE" ]; then
  echo "Reusing existing database credentials ($CRED_FILE)."
  fresh_credentials=false
  check_db_credentials_file "$CRED_FILE"
  cp "$CRED_FILE" "$tmp_cred"
  # A hand-edited file may lack a final newline; without this the first
  # appended key would be glued onto (and corrupt) the last value.
  if [ -s "$tmp_cred" ] && [ -n "$(tail -c 1 "$tmp_cred")" ]; then echo >> "$tmp_cred"; fi
  # shellcheck disable=SC1090
  . "$CRED_FILE"
else
  echo "Generating database credentials -> $CRED_FILE"
fi
# Append only what is missing, so upgrading an older file keeps its values.
[ -n "${POSTGRES_PASSWORD:-}" ] || echo "POSTGRES_PASSWORD=$(gen_secret 32)" >> "$tmp_cred"
[ -n "${MONGODB_USERNAME:-}" ] || echo "MONGODB_USERNAME=root" >> "$tmp_cred"
[ -n "${MONGODB_PASSWORD:-}" ] || echo "MONGODB_PASSWORD=$(gen_secret 32)" >> "$tmp_cred"
[ -n "${REDIS_PASSWORD:-}" ] || echo "REDIS_PASSWORD=$(gen_secret 32)" >> "$tmp_cred"
[ -n "${APP_POSTGRES_PASSWORD:-}" ] || echo "APP_POSTGRES_PASSWORD=$(gen_secret 32)" >> "$tmp_cred"
[ -n "${APP_MONGODB_PASSWORD:-}" ] || echo "APP_MONGODB_PASSWORD=$(gen_secret 32)" >> "$tmp_cred"
[ -n "${APP_REDIS_PASSWORD:-}" ] || echo "APP_REDIS_PASSWORD=$(gen_secret 32)" >> "$tmp_cred"
# shellcheck disable=SC1090
. "$tmp_cred"

# PostgreSQL and MongoDB only read their initial credentials when the data
# directory is empty. If volumes already exist (e.g. from the earlier
# no-auth version of these manifests), new credentials would NOT take
# effect — PostgreSQL would even keep its old "trust" rule. Refuse rather
# than silently leave an open database behind.
# A missing namespace is simply an empty list (exit 0); any other error
# (API unreachable, RBAC, timeout) must stop the install rather than be
# mistaken for "no old volumes".
all_pvcs=$(kc get pvc -n "$NAMESPACE" -o name) \
  || die "Could not list PVCs in namespace '$NAMESPACE'; refusing to continue."
existing_pvcs=$(printf '%s\n' "$all_pvcs" \
  | grep -E '^persistentvolumeclaim/(postgres|mongodb)-data$' || true)
if [ "$fresh_credentials" = true ] && [ -n "$existing_pvcs" ]; then
  die "Existing database volumes found in namespace '$NAMESPACE' but no saved credentials.
New passwords would be ignored by the already-initialised databases.
See 'Upgrading from the No-Auth Setup' in docs/databases.md."
fi

mv "$tmp_cred" "$CRED_FILE"
tmp_cred=""
chmod 600 "$CRED_FILE"

# --- Secrets for the database servers --------------------------------------
echo "Creating namespace '$NAMESPACE' (if missing)..."
kc apply -f "$REPO_ROOT/kubernetes/databases/namespace.yaml"

echo "Creating credential Secrets..."
work=$(mktemp -d)
printf '%s' "$POSTGRES_PASSWORD" > "$work/pg-password"
printf '%s' "$MONGODB_USERNAME" > "$work/mongo-username"
printf '%s' "$MONGODB_PASSWORD" > "$work/mongo-password"
printf '%s' "$REDIS_PASSWORD" > "$work/redis-password"
# The default user keeps full rights (operator use only); the application
# user may use data commands but nothing administrative or dangerous
# (CONFIG, FLUSHALL, KEYS, DEBUG, ACL, ...).
{
  printf 'requirepass %s\n' "$REDIS_PASSWORD"
  printf 'user hello-devops on >%s ~* &* +@all -@admin -@dangerous\n' "$APP_REDIS_PASSWORD"
} > "$work/redis.conf"

# apply_secret <namespace> <name> <kubectl create secret args...>
# Prints kubectl's action on stdout: created, configured or unchanged.
apply_secret() {
  ns=$1 name=$2
  shift 2
  out=$(kc create secret generic "$name" -n "$ns" "$@" \
    --dry-run=client -o yaml | kc apply -f -)
  echo "$out" >&2
  echo "${out##* }"
}
apply_secret "$NAMESPACE" postgres-credentials --from-file=password="$work/pg-password" >/dev/null
apply_secret "$NAMESPACE" mongodb-credentials \
  --from-file=username="$work/mongo-username" \
  --from-file=password="$work/mongo-password" >/dev/null
redis_secret_action=$(apply_secret "$NAMESPACE" redis-credentials \
  --from-file=password="$work/redis-password" \
  --from-file=redis.conf="$work/redis.conf")
# Passwords of the hello-devops app users, read by the provisioning Job.
printf '%s' "$APP_POSTGRES_PASSWORD" > "$work/app-pg-password"
printf '%s' "$APP_MONGODB_PASSWORD" > "$work/app-mongo-password"
apply_secret "$NAMESPACE" hello-devops-app-db \
  --from-file=postgres-password="$work/app-pg-password" \
  --from-file=mongodb-password="$work/app-mongo-password" >/dev/null

# A finished Job is immutable and never re-runs, so remove the previous one;
# applying the manifests then creates a fresh run that (re)provisions the
# app users with the current passwords.
kc delete job "$USERS_JOB" -n "$NAMESPACE" --ignore-not-found --wait=true >/dev/null

echo "Applying database manifests..."
kc apply -k "$REPO_ROOT/kubernetes/databases"

# Redis reads its config file only at start-up, so restart it when an
# existing config was modified. A just-created Secret needs no restart:
# the pod that apply -k starts reads it on its first start.
if [ "$redis_secret_action" = configured ]; then
  echo "Redis configuration changed — restarting Redis..."
  kc rollout restart deploy/redis -n "$NAMESPACE"
fi

echo "Waiting for databases to become ready..."
for app in postgres mongodb redis; do
  kc rollout status deploy/"$app" -n "$NAMESPACE" --timeout=300s
done

# --- least-privilege application users (hello-devops) ----------------------
# Created by the Job in kubernetes/databases/app-users-job.yaml (declarative,
# so it also runs when Argo CD syncs those manifests). Redis's app user is
# the ACL line in redis.conf above.
echo "Waiting for the hello-devops database users to be provisioned..."
state=""
i=0
# The Job's containers wait up to 10 minutes for their databases; allow a
# little longer here so their own error (not this timeout) is reported.
while [ "$i" -lt 330 ]; do
  i=$((i + 1))
  state=$(kc get job "$USERS_JOB" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)
  case "$state" in *Complete*|*Failed*) break ;; esac
  sleep 2
done
case "$state" in
  *Complete*) echo "hello-devops database users are up to date." ;;
  *)
    echo "Provisioning Job '$USERS_JOB' did not complete (state: ${state:-timeout}). Last log lines:" >&2
    kc logs "job/$USERS_JOB" -n "$NAMESPACE" --all-containers --tail=20 >&2 || true
    die "Could not create/update the hello-devops database users."
    ;;
esac

# Publish the application credentials where the application runs. The
# namespaces are owned by kubernetes/argocd/projects/; skip absent ones.
printf 'hello_devops' > "$work/app-pguser"
printf '%s' "$APP_POSTGRES_PASSWORD" > "$work/app-pgpassword"
printf 'mongodb://hello-devops:%s@mongodb.databases.svc.cluster.local:27017/hello-devops?authSource=hello-devops' \
  "$APP_MONGODB_PASSWORD" > "$work/app-mongodb-uri"
printf 'hello-devops' > "$work/app-redis-username"
printf '%s' "$APP_REDIS_PASSWORD" > "$work/app-redis-password"
for ns in $APP_NAMESPACES; do
  if kc get namespace "$ns" >/dev/null 2>&1; then
    apply_secret "$ns" "$APP_SECRET" \
      --from-file=PGUSER="$work/app-pguser" \
      --from-file=PGPASSWORD="$work/app-pgpassword" \
      --from-file=MONGODB_URI="$work/app-mongodb-uri" \
      --from-file=REDIS_USERNAME="$work/app-redis-username" \
      --from-file=REDIS_PASSWORD="$work/app-redis-password" >/dev/null
  else
    echo "Namespace '$ns' not found — skipping $APP_SECRET there (apply kubernetes/argocd/projects/ and re-run)."
  fi
done

echo
echo "Databases are running in namespace '$NAMESPACE'."
echo "Credentials: make databases-password"
echo "Status:      make databases-status"
