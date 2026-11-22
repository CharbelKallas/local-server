#!/bin/sh
# Print the local Argo CD UI URL and open it in the default browser.
set -eu
. "$(dirname -- "$0")/lib.sh"

NAMESPACE="argocd"

require_cluster

PORT=$(kc get svc argocd-server -n "$NAMESPACE" -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || true)
[ -n "$PORT" ] || die "argocd-server is not exposed via NodePort. Run: make argocd-install"

echo "Argo CD UI: https://localhost:$PORT"
if command -v open >/dev/null 2>&1; then
  open "https://localhost:$PORT"
fi
