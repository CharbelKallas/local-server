#!/bin/sh
# Show the status of the Linux VM.
set -eu
. "$(dirname -- "$0")/lib.sh"

require_cmd limactl

echo "== Lima instances =="
limactl list

echo
status=$(vm_status)
if [ -z "$status" ]; then
  echo "VM '$VM_NAME' does not exist yet. Run: make vm-start"
elif [ "$status" != "Running" ]; then
  echo "VM '$VM_NAME' is $status. Run: make vm-start"
else
  echo "== VM '$VM_NAME' details =="
  # shellcheck disable=SC2016  # expands inside the VM
  limactl shell "$VM_NAME" -- sh -c 'echo "OS:        $(. /etc/os-release && echo "$PRETTY_NAME")"; echo "Kernel:    $(uname -r)"; echo "Uptime:    $(uptime -p)"; echo "CPU count: $(nproc)"; echo "Memory:    $(free -h | awk "/^Mem:/ {print \$2}")"'
fi
