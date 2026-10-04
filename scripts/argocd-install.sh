#!/bin/sh
# Install (or update) Argo CD in the K3s cluster using the normal
# Kubernetes installation method: the official stable manifests (non-HA).
#
# The argocd-server Service is exposed on NodePort 30080 so the UI is
# reachable at https://localhost:30080 (Lima forwards guest ports
# 30000-32767 to the same ports on the macOS host — see vm/k3s.yaml).
#
# Idempotent: safe to re-run.
set -eu

NAMESPACE="argocd"
NODE_PORT="30080"

if ! kubectl get nodes >/dev/null 2>&1; then
  echo "Cannot reach the K3s cluster. Run: make k3s-start" >&2
  exit 1
fi

echo "Creating namespace '$NAMESPACE' (if missing)..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "Installing Argo CD (official stable manifests)..."
# Server-side apply: the applicationsets CRD is larger than the 256 KiB
# last-applied-configuration annotation limit of client-side apply.
# --force-conflicts takes field ownership from the earlier client-side
# apply (a no-op on a fresh install).
kubectl apply --server-side --force-conflicts -n "$NAMESPACE" \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Expose the UI via NodePort. The manifest defines the https port second
# (index 1); verify afterwards so a manifest reorder can't silently break it.
if [ "$(kubectl get svc argocd-server -n "$NAMESPACE" -o jsonpath='{.spec.type}')" != "NodePort" ]; then
  echo "Exposing argocd-server on NodePort $NODE_PORT..."
  kubectl patch svc argocd-server -n "$NAMESPACE" --type=json \
    -p '[{"op":"replace","path":"/spec/type","value":"NodePort"},{"op":"add","path":"/spec/ports/1/nodePort","value":'"$NODE_PORT"'}]'
fi

if [ "$(kubectl get svc argocd-server -n "$NAMESPACE" -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')" != "$NODE_PORT" ]; then
  echo "Failed to expose the argocd-server https port on NodePort $NODE_PORT." >&2
  exit 1
fi

echo "Waiting for Argo CD pods to become ready..."
kubectl wait --for=condition=ready pod --all -n "$NAMESPACE" --timeout=300s

echo
echo "Argo CD is installed."
echo "UI:  https://localhost:$NODE_PORT   (user: admin, get password: make argocd-password)"
