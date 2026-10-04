#!/bin/sh
# Show K3s cluster status: service state, nodes, and system pods.
set -eu

NAME="k3s"

if ! limactl list | awk 'NR>1 {print $1}' | grep -qx "$NAME"; then
  echo "VM '$NAME' does not exist. Run: make vm-start" >&2
  exit 1
fi

if [ "$(limactl list | awk -v n="$NAME" '$1 == n {print $2}')" != "Running" ]; then
  echo "VM '$NAME' is not running. Run: make vm-start" >&2
  exit 1
fi

echo "== K3s service status =="
limactl shell "$NAME" -- sudo systemctl is-active k3s

echo
echo "== Nodes =="
limactl shell "$NAME" -- sudo kubectl get nodes -o wide

echo
echo "== System pods =="
limactl shell "$NAME" -- sudo kubectl get pods -n kube-system
