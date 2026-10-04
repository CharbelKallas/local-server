#!/bin/sh
# Start the Linux VM (named "k3s") used for the local K3s cluster.
# Creates it from vm/k3s.yaml on first run, then just starts it.
set -eu

NAME="k3s"
CONFIG="$(dirname "$0")/../vm/k3s.yaml"

if limactl list | awk 'NR>1 {print $1}' | grep -qx "$NAME"; then
  echo "Starting existing VM '$NAME'..."
  limactl start "$NAME"
else
  echo "Creating VM '$NAME' from vm/k3s.yaml (first run, may take a few minutes)..."
  limactl start --name="$NAME" "$CONFIG"
fi

limactl list
