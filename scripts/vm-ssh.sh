#!/bin/sh
# Open an interactive shell on the Linux VM (named "k3s").
# Usage: make vm-ssh   (or pass commands: scripts/vm-ssh.sh "uname -a")
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

if [ $# -gt 0 ]; then
  exec limactl shell "$NAME" -- bash -lc "$*"
else
  exec limactl shell "$NAME"
fi
