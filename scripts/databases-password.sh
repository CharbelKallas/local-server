#!/bin/sh
# Print the lab database credentials (from the gitignored secrets/ file).
set -eu
. "$(dirname -- "$0")/lib.sh"

CRED_FILE="$SECRETS_DIR/databases.env"

[ -f "$CRED_FILE" ] || die "No database credentials found. Run: make databases-install"

# shellcheck disable=SC1090
. "$CRED_FILE"

echo "PostgreSQL: user postgres, database lab, password ${POSTGRES_PASSWORD:-?}"
echo "MongoDB:    user ${MONGODB_USERNAME:-?}, password ${MONGODB_PASSWORD:-?} (authSource admin)"
echo "Redis:      password ${REDIS_PASSWORD:-?}"
