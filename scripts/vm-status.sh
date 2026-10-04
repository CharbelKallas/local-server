#!/bin/sh
# Show the status of the Linux VM (named "k3s").
set -eu

NAME="k3s"

echo "== Lima instances =="
limactl list

if limactl list | awk 'NR>1 {print $1}' | grep -qx "$NAME"; then
  echo
  echo "== VM '$NAME' details =="
  limactl shell "$NAME" -- sh -c 'echo "OS:        $(. /etc/os-release && echo $PRETTY_NAME)"; echo "Kernel:    $(uname -r)"; echo "Uptime:    $(uptime -p)"; echo "CPU count: $(nproc)"; echo "Memory:    $(free -h | awk "/^Mem:/ {print \$2}")"'
else
  echo
  echo "VM '$NAME' does not exist yet. Run: make vm-start"
fi
