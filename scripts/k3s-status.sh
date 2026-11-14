#!/bin/sh
# Show K3s cluster status: service state, nodes, and system pods.
set -eu
. "$(dirname -- "$0")/lib.sh"

require_vm_running

echo "== K3s service status =="
# `systemctl is-active` exits non-zero for an inactive unit; report it
# instead of aborting under `set -e`.
state=$(limactl shell "$VM_NAME" -- systemctl is-active k3s 2>/dev/null || true)
echo "${state:-unknown}"
if [ "$state" != "active" ]; then
  echo "K3s is not running. Run: make k3s-start" >&2
  exit 1
fi

echo
echo "== Nodes =="
limactl shell "$VM_NAME" -- sudo k3s kubectl get nodes -o wide

echo
echo "== System pods =="
limactl shell "$VM_NAME" -- sudo k3s kubectl get pods -n kube-system
