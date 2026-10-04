#!/bin/sh
# Print the Kargo admin account password.
#
# Unlike Argo CD (whose initial password lives in a Secret), Kargo's admin
# password is set at install time via a bcrypt hash, so the plaintext is kept
# only in the local, gitignored credentials file created by kargo-install.sh.
set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CRED_FILE="$REPO_ROOT/secrets/kargo-admin.env"

if [ ! -f "$CRED_FILE" ]; then
  echo "No Kargo credentials found. Run: make kargo-install" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$CRED_FILE"

if [ -z "${KARGO_ADMIN_PASSWORD:-}" ]; then
  echo "KARGO_ADMIN_PASSWORD missing from $CRED_FILE" >&2
  exit 1
fi

echo "Kargo admin username: admin"
echo "Kargo admin password: $KARGO_ADMIN_PASSWORD"
