#!/bin/sh
# Deploy PostgreSQL, MongoDB and Redis into the K3s cluster (namespace
# "databases") with password authentication.
#
# 1. Generates credentials once into secrets/databases.env (gitignored,
#    mode 600) and reuses them on re-runs.
# 2. Creates/updates the three credential Secrets in the cluster. Values
#    are passed to kubectl through private temp files, never on the
#    command line.
# 3. Applies kubernetes/databases/ (kustomize) and waits for the rollouts.
#
# Idempotent: safe to re-run.
set -eu
. "$(dirname -- "$0")/lib.sh"

NAMESPACE="databases"
CRED_FILE="$SECRETS_DIR/databases.env"

require_cluster
require_cmd openssl

umask 077
fresh_credentials=false
if [ -f "$CRED_FILE" ]; then
  echo "Reusing existing database credentials ($CRED_FILE)."
else
  echo "Generating database credentials -> $CRED_FILE"
  ensure_secrets_dir
  tmp_cred=$(mktemp "$CRED_FILE.XXXXXX")
  {
    printf 'POSTGRES_PASSWORD=%s\n' "$(gen_secret 32)"
    printf 'MONGODB_USERNAME=%s\n' "root"
    printf 'MONGODB_PASSWORD=%s\n' "$(gen_secret 32)"
    printf 'REDIS_PASSWORD=%s\n' "$(gen_secret 32)"
  } > "$tmp_cred"
  mv "$tmp_cred" "$CRED_FILE"
  fresh_credentials=true
fi
chmod 600 "$CRED_FILE"

# shellcheck disable=SC1090
. "$CRED_FILE"
for var in POSTGRES_PASSWORD MONGODB_USERNAME MONGODB_PASSWORD REDIS_PASSWORD; do
  eval "val=\${$var:-}"
  # shellcheck disable=SC2154
  [ -n "$val" ] || die "$var missing from $CRED_FILE (delete the file and re-run)."
done

# PostgreSQL and MongoDB only read their initial credentials when the data
# directory is empty. If volumes already exist (e.g. from the earlier
# no-auth version of these manifests), new credentials would NOT take
# effect — PostgreSQL would even keep its old "trust" rule. Refuse rather
# than silently leave an open database behind.
existing_pvcs=$(kc get pvc -n "$NAMESPACE" -o name 2>/dev/null \
  | grep -E '^persistentvolumeclaim/(postgres|mongodb)-data$' || true)
if [ "$fresh_credentials" = true ] && [ -n "$existing_pvcs" ]; then
  rm -f "$CRED_FILE"
  die "Existing database volumes found in namespace '$NAMESPACE' but no saved credentials.
New passwords would be ignored by the already-initialised databases.
See 'Upgrading from the No-Auth Setup' in docs/databases.md."
fi

echo "Creating namespace '$NAMESPACE' (if missing)..."
kc apply -f "$REPO_ROOT/kubernetes/databases/namespace.yaml"

echo "Creating credential Secrets..."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM
printf '%s' "$POSTGRES_PASSWORD" > "$work/pg-password"
printf '%s' "$MONGODB_USERNAME" > "$work/mongo-username"
printf '%s' "$MONGODB_PASSWORD" > "$work/mongo-password"
printf '%s' "$REDIS_PASSWORD" > "$work/redis-password"
printf 'requirepass %s\n' "$REDIS_PASSWORD" > "$work/redis.conf"

apply_secret() {
  name=$1
  shift
  kc create secret generic "$name" -n "$NAMESPACE" "$@" \
    --dry-run=client -o yaml | kc apply -f -
}
apply_secret postgres-credentials --from-file=password="$work/pg-password"
apply_secret mongodb-credentials \
  --from-file=username="$work/mongo-username" \
  --from-file=password="$work/mongo-password"
apply_secret redis-credentials \
  --from-file=password="$work/redis-password" \
  --from-file=redis.conf="$work/redis.conf"

echo "Applying database manifests..."
kc apply -k "$REPO_ROOT/kubernetes/databases"

echo "Waiting for databases to become ready..."
for app in postgres mongodb redis; do
  kc rollout status deploy/"$app" -n "$NAMESPACE" --timeout=300s
done

echo
echo "Databases are running in namespace '$NAMESPACE'."
echo "Credentials: make databases-password"
echo "Status:      make databases-status"
