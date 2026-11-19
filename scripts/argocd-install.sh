#!/bin/sh
# Install (or update) Argo CD in the K3s cluster from the official,
# version-pinned manifests (non-HA).
#
# The argocd-server Service is exposed on NodePort 30080 so the UI is
# reachable at https://localhost:30080 (Lima forwards guest ports
# 30000-32767 to the same ports on the macOS host — see vm/k3s.yaml).
#
# Idempotent: safe to re-run. Bumping ARGOCD_VERSION and re-running upgrades.
set -eu
. "$(dirname -- "$0")/lib.sh"

NAMESPACE="argocd"
NODE_PORT="30080"
ARGOCD_VERSION="v3.6.1"   # keep in sync with docs/argocd.md
# sha256 of that release's install.yaml — update together with the version.
ARGOCD_MANIFEST_SHA256="7be23ca7d9ca3d3074dee8332f1ca92a933b990cee7c9cf22cf3843ee8c2913e"
DEFAULT_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"

require_cluster

# ARGOCD_MANIFEST may point at another copy of the same manifest (a local
# file for offline installs, an https mirror, or the e2e test's one
# download). Whatever the source, it must hash to ARGOCD_MANIFEST_SHA256.
trap 'rm -f "$PINNED_TMP"' EXIT
trap 'exit 130' INT TERM
use_pinned_manifest "${ARGOCD_MANIFEST:-$DEFAULT_MANIFEST}" "$ARGOCD_MANIFEST_SHA256" ARGOCD_MANIFEST
MANIFEST=$PINNED_MANIFEST

echo "Creating namespace '$NAMESPACE' (if missing)..."
kc create namespace "$NAMESPACE" --dry-run=client -o yaml | kc apply -f -

echo "Installing Argo CD $ARGOCD_VERSION (official manifests)..."
# Server-side apply: the applicationsets CRD is larger than the 256 KiB
# last-applied-configuration annotation limit of client-side apply.
# --force-conflicts takes field ownership from an earlier client-side
# apply (a no-op on a fresh install).
kc apply --server-side --force-conflicts -n "$NAMESPACE" -f "$MANIFEST"

# Expose the UI via NodePort. A strategic-merge patch matches the port by
# its port number (443), so it neither depends on the order of ports in the
# upstream manifest nor breaks if the Service is already a NodePort with a
# different (random) nodePort.
echo "Exposing argocd-server on NodePort $NODE_PORT..."
kc patch svc argocd-server -n "$NAMESPACE" --type=strategic \
  -p '{"spec":{"type":"NodePort","ports":[{"port":443,"nodePort":'"$NODE_PORT"'}]}}'

if [ "$(kc get svc argocd-server -n "$NAMESPACE" -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')" != "$NODE_PORT" ]; then
  die "Failed to expose the argocd-server https port on NodePort $NODE_PORT."
fi

echo "Waiting for Argo CD workloads to become ready..."
# Wait on the controllers rather than on every pod: a pod left over from a
# previous ReplicaSet (or a Completed job pod) never becomes Ready.
kc rollout status deploy -n "$NAMESPACE" --timeout=300s
kc rollout status statefulset -n "$NAMESPACE" --timeout=300s

echo
echo "Argo CD $ARGOCD_VERSION is installed."
echo "UI:  https://localhost:$NODE_PORT   (user: admin, get password: make argocd-password)"
