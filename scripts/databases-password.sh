#!/bin/sh
# Print the lab database credentials (from the gitignored secrets/ file).
set -eu
. "$(dirname -- "$0")/lib.sh"

CRED_FILE="$SECRETS_DIR/databases.env"

[ -f "$CRED_FILE" ] || die "No database credentials found. Run: make databases-install"

clear_db_credentials
# shellcheck disable=SC1090
. "$CRED_FILE"

echo "PostgreSQL: user postgres, database lab, password ${POSTGRES_PASSWORD:-?}"
echo "MongoDB:    user ${MONGODB_USERNAME:-?}, password ${MONGODB_PASSWORD:-?} (authSource admin)"
echo "Redis:      password ${REDIS_PASSWORD:-?}"
echo
echo "hello-devops application users (least privilege; also in Secret"
echo "hello-devops-db-credentials in the hello-devops namespaces):"
echo "PostgreSQL: user hello_devops, database lab, password ${APP_POSTGRES_PASSWORD:-?}"
echo "MongoDB:    user hello-devops, database hello-devops, password ${APP_MONGODB_PASSWORD:-?}"
echo "Redis:      user hello-devops, password ${APP_REDIS_PASSWORD:-?}"
