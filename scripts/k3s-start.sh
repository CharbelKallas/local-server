#!/bin/sh
# Start the K3s service inside the Linux VM, installing K3s first if needed.
#
# The K3s version is pinned (K3S_VERSION) so a fresh install or a VM rebuild
# gets the same Kubernetes version as the one this lab is documented against,
# instead of whatever the "stable" channel happens to serve that day.
set -eu
. "$(dirname -- "$0")/lib.sh"

# Keep in sync with docs/k3s.md, and with the Pod Security
# `enforce-version` (v1.36) on the lab namespaces when bumping the minor.
K3S_VERSION="v1.36.5+k3s1"
# The installer script of that release (not the moving get.k3s.io one), and
# its sha256 — update both together with the version.
K3S_INSTALLER="https://raw.githubusercontent.com/k3s-io/k3s/$K3S_VERSION/install.sh"
K3S_INSTALLER_SHA256="46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad"

require_vm_running

if ! limactl shell "$VM_NAME" -- sh -c 'command -v k3s >/dev/null 2>&1'; then
  echo "K3s not installed. Installing K3s $K3S_VERSION..."
  # Downloaded and sha256-verified here on the host, then streamed into the
  # VM and saved before running it as root — never a network stream piped
  # into a root shell. The installer itself verifies the K3s binary's
  # sha256 against the release checksums.
  trap 'rm -f "$PINNED_TMP"' EXIT
  trap 'exit 130' INT TERM
  use_pinned_download "$K3S_INSTALLER" "$K3S_INSTALLER_SHA256" K3S_INSTALLER
  # Single quotes are deliberate: these expand inside the VM, not here.
  # shellcheck disable=SC2016
  limactl shell "$VM_NAME" -- sh -c '
    set -eu
    tmp=$(mktemp)
    trap "rm -f \"$tmp\"" EXIT
    cat > "$tmp"
    sudo INSTALL_K3S_VERSION="$1" INSTALL_K3S_FORCE_RESTART=true sh "$tmp"
  ' sh "$K3S_VERSION" < "$PINNED_FILE"
fi

echo "Starting K3s service..."
limactl shell "$VM_NAME" -- sudo systemctl start k3s

echo "Waiting for K3s to be ready..."
# The wait logic lives in its own file (linted like every other script) and
# is streamed into the VM's shell on stdin.
limactl shell "$VM_NAME" -- sh -s < "$REPO_ROOT/scripts/vm/k3s-wait-ready.sh"
