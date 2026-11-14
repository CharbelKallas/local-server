#!/bin/sh
# Start the K3s service inside the Linux VM, installing K3s first if needed.
#
# The K3s version is pinned (K3S_VERSION) so a fresh install or a VM rebuild
# gets the same Kubernetes version as the one this lab is documented against,
# instead of whatever the "stable" channel happens to serve that day.
set -eu
. "$(dirname -- "$0")/lib.sh"

K3S_VERSION="${K3S_VERSION:-v1.36.5+k3s1}"   # keep in sync with docs/k3s.md

require_vm_running

if ! limactl shell "$VM_NAME" -- sh -c 'command -v k3s >/dev/null 2>&1'; then
  echo "K3s not installed. Installing K3s $K3S_VERSION..."
  # Download first, then run: never pipe a network stream straight into a
  # root shell (a truncated download would execute a partial script).
  # Single quotes are deliberate: these expand inside the VM, not here.
  # shellcheck disable=SC2016
  # The installer verifies the binary's sha256 against the release checksums.
  limactl shell "$VM_NAME" -- sh -c '
    set -eu
    tmp=$(mktemp)
    trap "rm -f \"$tmp\"" EXIT
    curl -sfL https://get.k3s.io -o "$tmp"
    sudo INSTALL_K3S_VERSION="$1" INSTALL_K3S_FORCE_RESTART=true sh "$tmp"
  ' sh "$K3S_VERSION"
fi

echo "Starting K3s service..."
limactl shell "$VM_NAME" -- sudo systemctl start k3s

echo "Waiting for K3s to be ready..."
# shellcheck disable=SC2016  # expands inside the VM
limactl shell "$VM_NAME" -- sh -c 'for i in $(seq 1 60); do
  if sudo k3s kubectl get nodes 2>/dev/null | grep -q " Ready "; then
    echo "K3s is ready."
    exit 0
  fi
  sleep 2
done
echo "K3s did not become ready in time. Check: make k3s-status" >&2
exit 1'
