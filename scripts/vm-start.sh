#!/bin/sh
# Start the Linux VM used for the local K3s cluster.
# Creates it from vm/k3s.yaml on first run, then just starts it.
set -eu
. "$(dirname -- "$0")/lib.sh"

require_cmd limactl "Install Lima first (brew install lima)."

if vm_exists; then
  echo "Starting existing VM '$VM_NAME'..."
  limactl start "$VM_NAME"
else
  echo "Creating VM '$VM_NAME' from vm/k3s.yaml (first run, may take a few minutes)..."
  limactl start --name="$VM_NAME" "$REPO_ROOT/vm/k3s.yaml"
fi

limactl list "$VM_NAME"
