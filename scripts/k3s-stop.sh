#!/bin/sh
# Stop the K3s service inside the Linux VM.
set -eu
. "$(dirname -- "$0")/lib.sh"

require_cmd limactl

status=$(vm_status)
if [ -z "$status" ]; then
  echo "VM '$VM_NAME' does not exist. Nothing to stop."
  exit 0
fi

if [ "$status" != "Running" ]; then
  echo "VM '$VM_NAME' is not running. Nothing to stop."
  exit 0
fi

echo "Stopping K3s service..."
limactl shell "$VM_NAME" -- sudo systemctl stop k3s
echo "K3s stopped."
