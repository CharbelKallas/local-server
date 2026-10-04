#!/bin/sh
# Stop the K3s service inside the Linux VM (named "k3s").
set -eu

NAME="k3s"

if ! limactl list | awk 'NR>1 {print $1}' | grep -qx "$NAME"; then
  echo "VM '$NAME' does not exist. Nothing to stop."
  exit 0
fi

if [ "$(limactl list | awk -v n="$NAME" '$1 == n {print $2}')" != "Running" ]; then
  echo "VM '$NAME' is not running. Nothing to stop."
  exit 0
fi

echo "Stopping K3s service..."
limactl shell "$NAME" -- sudo systemctl stop k3s
echo "K3s stopped."
