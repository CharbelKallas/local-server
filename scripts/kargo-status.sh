#!/bin/sh
# Show Kargo status: pods, workloads, services, CRDs, and the UI address.
set -eu
. "$(dirname -- "$0")/lib.sh"

NAMESPACE="kargo"

require_cluster

if ! kc get ns "$NAMESPACE" >/dev/null 2>&1; then
  die "Kargo is not installed (namespace '$NAMESPACE' not found). Run: make kargo-install"
fi

echo "== Pods =="
kc get pods -n "$NAMESPACE"

echo
echo "== Workloads =="
kc get deploy -n "$NAMESPACE"

echo
echo "== Services =="
kc get svc -n "$NAMESPACE"

echo
echo "== Kargo CRDs =="
kc get crd -o name 2>/dev/null | grep '\.kargo\.akuity\.io$' || echo "(none found)"

echo
echo "== Helm release =="
hc list -n "$NAMESPACE" 2>/dev/null || true

echo
echo "== cert-manager (dependency) =="
kc get pods -n cert-manager 2>/dev/null || echo "(not installed)"

echo
PORT=$(kc get svc kargo-api -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)
if [ -n "$PORT" ]; then
  echo "UI: https://localhost:$PORT  (user: admin, password: make kargo-password)"
else
  echo "UI: kargo-api is not exposed (run: make kargo-install)."
fi
