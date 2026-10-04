#!/bin/sh
# Print the local Argo CD UI URL and open it in the default browser.
set -eu

NAMESPACE="argocd"

if ! kubectl get nodes >/dev/null 2>&1; then
  echo "Cannot reach the K3s cluster. Run: make k3s-start" >&2
  exit 1
fi

PORT=$(kubectl get svc argocd-server -n "$NAMESPACE" -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || true)
if [ -z "$PORT" ]; then
  echo "argocd-server is not exposed via NodePort. Run: make argocd-install" >&2
  exit 1
fi

echo "Argo CD UI: https://localhost:$PORT"
open "https://localhost:$PORT"
