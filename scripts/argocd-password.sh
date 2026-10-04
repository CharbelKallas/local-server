#!/bin/sh
# Print the Argo CD initial admin password.
set -eu

NAMESPACE="argocd"

if ! kubectl get nodes >/dev/null 2>&1; then
  echo "Cannot reach the K3s cluster. Run: make k3s-start" >&2
  exit 1
fi

SECRET=$(kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null || true)
if [ -z "$SECRET" ]; then
  echo "Initial admin secret not found — it is removed after the first login." >&2
  echo "If you have already logged in, reset the password instead (see docs/argocd.md)." >&2
  exit 1
fi

echo "Initial admin password: $(printf %s "$SECRET" | base64 -d)"
