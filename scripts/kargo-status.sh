#!/bin/sh
# Show Kargo status: pods, workloads, services, CRDs, and the UI address.
set -eu

NAMESPACE="kargo"

if ! kubectl get nodes >/dev/null 2>&1; then
  echo "Cannot reach the K3s cluster. Run: make k3s-start" >&2
  exit 1
fi

if ! kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  echo "Kargo is not installed (namespace '$NAMESPACE' not found). Run: make kargo-install" >&2
  exit 1
fi

echo "== Pods =="
kubectl get pods -n "$NAMESPACE"

echo
echo "== Workloads =="
kubectl get deploy -n "$NAMESPACE"

echo
echo "== Services =="
kubectl get svc -n "$NAMESPACE"

echo
echo "== Kargo CRDs =="
kubectl get crd -o name 2>/dev/null | grep '\.kargo\.akuity\.io$' || echo "(none found)"

echo
echo "== Helm release =="
helm list -n "$NAMESPACE" 2>/dev/null || true

echo
echo "== cert-manager (dependency) =="
kubectl get pods -n cert-manager 2>/dev/null || echo "(not installed)"

echo
PORT=$(kubectl get svc kargo-api -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)
if [ -n "$PORT" ]; then
  echo "UI: https://localhost:$PORT  (user: admin, password: make kargo-password)"
else
  echo "UI: kargo-api is not exposed (run: make kargo-install)."
fi
