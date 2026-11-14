#!/bin/sh
# Show the status of the lab databases (namespace "databases").
set -eu
. "$(dirname -- "$0")/lib.sh"

NAMESPACE="databases"

require_cluster

if ! kc get ns "$NAMESPACE" >/dev/null 2>&1; then
  die "Databases are not deployed (namespace '$NAMESPACE' not found). Run: make databases-install"
fi

echo "== Workloads =="
kc get deploy -n "$NAMESPACE"

echo
echo "== Pods =="
kc get pods -n "$NAMESPACE"

echo
echo "== Services =="
kc get svc -n "$NAMESPACE"

echo
echo "== Storage =="
kc get pvc -n "$NAMESPACE"
