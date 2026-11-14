#!/bin/sh
# Print the Kargo admin account password.
#
# Unlike Argo CD (whose initial password lives in a Secret), Kargo's admin
# password is set at install time via a bcrypt hash, so the plaintext is kept
# only in the local, gitignored credentials file created by kargo-install.sh.
set -eu
. "$(dirname -- "$0")/lib.sh"

CRED_FILE="$SECRETS_DIR/kargo-admin.env"

[ -f "$CRED_FILE" ] || die "No Kargo credentials found. Run: make kargo-install"

# shellcheck disable=SC1090
. "$CRED_FILE"

[ -n "${KARGO_ADMIN_PASSWORD:-}" ] || die "KARGO_ADMIN_PASSWORD missing from $CRED_FILE"

echo "Kargo admin username: admin"
echo "Kargo admin password: $KARGO_ADMIN_PASSWORD"
