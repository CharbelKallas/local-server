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

echo
echo "== App-user provisioning Job =="
# Removed 10 minutes after it finishes (ttlSecondsAfterFinished).
# One query; the TTL may delete the Job at any moment, so absence is normal.
job=$(kc get job hello-devops-db-users -n "$NAMESPACE" \
  -o jsonpath='{.metadata.name} {.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)
if [ -n "$job" ]; then
  echo "$job"
  case "$job" in
    *Failed*) echo "Last run FAILED — logs: kubectl -n $NAMESPACE logs job/hello-devops-db-users --all-containers" ;;
  esac
else
  echo "(no recent run — it is removed 10 minutes after finishing; re-run: make databases-install)"
fi
