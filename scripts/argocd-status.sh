#!/bin/sh
# Show Argo CD status: pods, services, and the UI address.
set -eu
. "$(dirname -- "$0")/lib.sh"

NAMESPACE="argocd"

require_cluster

if ! kc get ns "$NAMESPACE" >/dev/null 2>&1; then
  die "Argo CD is not installed (namespace '$NAMESPACE' not found). Run: make argocd-install"
fi

echo "== Pods =="
kc get pods -n "$NAMESPACE"

echo
echo "== Services =="
kc get svc -n "$NAMESPACE"

echo
PORT=$(kc get svc argocd-server -n "$NAMESPACE" -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || true)
if [ -n "$PORT" ]; then
  echo "UI: https://localhost:$PORT"
else
  echo "UI: argocd-server is not exposed via NodePort (run: make argocd-install)."
fi
