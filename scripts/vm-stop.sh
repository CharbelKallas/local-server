#!/bin/sh
# Stop the Linux VM (named "k3s"). Graceful shutdown; add -f to force.
set -eu

NAME="k3s"

if ! limactl list | awk 'NR>1 {print $1}' | grep -qx "$NAME"; then
  echo "VM '$NAME' does not exist. Nothing to stop."
  exit 0
fi

echo "Stopping VM '$NAME'..."
limactl stop "$NAME"
