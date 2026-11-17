#!/bin/sh
# Stop the Linux VM (graceful shutdown).
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

echo "Stopping VM '$VM_NAME'..."
limactl stop "$VM_NAME"
