#!/bin/sh
# Start the K3s service inside the Linux VM (named "k3s").
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

if ! limactl shell "$NAME" -- sh -c 'command -v k3s >/dev/null 2>&1'; then
  echo "K3s not installed. Installing..."
  limactl shell "$NAME" -- sh -c 'curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh && sudo INSTALL_K3S_FORCE_RESTART=true sh /tmp/k3s-install.sh'
fi

echo "Starting K3s service..."
limactl shell "$NAME" -- sudo systemctl start k3s

echo "Waiting for K3s to be ready..."
limactl shell "$NAME" -- sh -c 'for i in $(seq 1 30); do
  if sudo kubectl get nodes >/dev/null 2>&1; then
    echo "K3s is ready."
    exit 0
  fi
  sleep 2
done
echo "K3s did not become ready in time. Check: make k3s-status" >&2
exit 1'
