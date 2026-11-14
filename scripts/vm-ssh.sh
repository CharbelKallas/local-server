#!/bin/sh
# Open an interactive shell on the Linux VM, or run one command in it.
# Usage: make vm-ssh   (or: scripts/vm-ssh.sh uname -a)
set -eu
. "$(dirname -- "$0")/lib.sh"

require_vm_running

if [ $# -gt 0 ]; then
  # Arguments are joined into one login-shell command line, so
  # scripts/vm-ssh.sh "uname -a" and scripts/vm-ssh.sh uname -a both work.
  exec limactl shell "$VM_NAME" -- bash -lc "$*"
else
  exec limactl shell "$VM_NAME"
fi
