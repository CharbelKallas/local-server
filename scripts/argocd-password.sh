#!/bin/sh
# Print the Argo CD initial admin password.
set -eu
. "$(dirname -- "$0")/lib.sh"

NAMESPACE="argocd"

require_cluster

SECRET=$(kc -n "$NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null || true)
if [ -z "$SECRET" ]; then
  echo "Secret 'argocd-initial-admin-secret' not found." >&2
  echo "It is gone once you have deleted it (recommended after changing the password)." >&2
  echo "To reset a lost password, see 'Reset the Admin Password' in docs/argocd.md." >&2
  exit 1
fi

echo "Initial admin password: $(printf %s "$SECRET" | base64 -d)"
