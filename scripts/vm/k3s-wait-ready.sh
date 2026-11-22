#!/bin/sh
# Runs INSIDE the VM (streamed in by scripts/k3s-start.sh via
# `limactl shell ... sh -s`): waits until K3s is really ready.
#
# "Ready" must be judged on fresh state: right after a VM boot the API still
# reports the node (and even pods) as Ready from before the shutdown, so a
# plain `get nodes | grep Ready` passes before anything works. Requires:
#   1. this node's kubelet lease renewed AFTER the current K3s service start
#      (proves the kubelet is running now, not a stale status),
#   2. CoreDNS and the local-path provisioner Ready, and
#   3. the API server's /readyz,
# all on 3 consecutive polls, giving the live kubelet time to correct any
# stale pod status. (Container start times can't be used: `k3s-stop` leaves
# pods running, so containers legitimately predate a restarted service.)
set -u

kc() { sudo k3s kubectl "$@"; }

started=$(systemctl show k3s -p ActiveEnterTimestamp --value)
# An empty/"n/a" timestamp must not become `date -d ""` (= midnight today),
# which would make a lease from before the shutdown look fresh.
case "$started" in
  "" | n/a) echo "Cannot determine when K3s started (systemctl)." >&2; exit 1 ;;
esac
since=$(date -d "$started" +%s)

# The kubelet's lease is named after the Kubernetes node, which is not
# necessarily the hostname (K3s lowercases it; --node-name overrides it).
# Resolve it via the node's kubernetes.io/hostname label once the API answers.
node=""
resolve_node() {
  [ -n "$node" ] && return 0
  node=$(kc get nodes -l "kubernetes.io/hostname=$(hostname | tr '[:upper:]' '[:lower:]')" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || node=""
  [ -n "$node" ]
}

lease_fresh() {
  renew=$(kc get lease "$node" -n kube-node-lease -o jsonpath='{.spec.renewTime}' 2>/dev/null)
  [ -n "$renew" ] && [ "$(date -d "$renew" +%s)" -ge "$since" ]
}

# One call for both system components: "<k8s-app><app> <Ready status>" lines.
pods_ready() {
  pods=$(kc get pods -n kube-system -o jsonpath='{range .items[*]}{.metadata.labels.k8s-app}{.metadata.labels.app} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null) \
    || return 1
  printf '%s\n' "$pods" | grep -qx 'kube-dns True' \
    && printf '%s\n' "$pods" | grep -qx 'local-path-provisioner True'
}

streak=0
i=0
while [ "$i" -lt 120 ]; do
  i=$((i + 1))
  # Cheapest, most-likely-to-fail checks first; && short-circuits the rest.
  if resolve_node && lease_fresh && pods_ready && kc get --raw=/readyz >/dev/null 2>&1; then
    streak=$((streak + 1))
    if [ "$streak" -ge 3 ]; then
      echo "K3s is ready."
      exit 0
    fi
  else
    streak=0
  fi
  sleep 2
done
echo "K3s did not become ready in time. Check: make k3s-status" >&2
exit 1
