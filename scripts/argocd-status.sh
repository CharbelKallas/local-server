#!/bin/sh
# Show Argo CD status: pods, services, and the UI address.
set -eu

NAMESPACE="argocd"

if ! kubectl get nodes >/dev/null 2>&1; then
  echo "Cannot reach the K3s cluster. Run: make k3s-start" >&2
  exit 1
fi

echo "== Pods =="
kubectl get pods -n "$NAMESPACE"

echo
echo "== Services =="
kubectl get svc -n "$NAMESPACE"

echo
PORT=$(kubectl get svc argocd-server -n "$NAMESPACE" -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || true)
if [ -n "$PORT" ]; then
  echo "UI: https://localhost:$PORT"
else
  echo "UI: argocd-server is not exposed via NodePort (run: make argocd-install)."
fi
