# K3s Cluster

## Where K3s Runs

K3s runs inside the Linux VM managed by Lima (instance name: `k3s`).

- **VM OS:** Ubuntu 24.04 LTS (arm64)
- **K3s version:** v1.36.5+k3s1 (pinned in `scripts/k3s-start.sh` as
  `K3S_VERSION`; a fresh install or VM rebuild gets exactly this version).
  The installer is that release's `install.sh` (not the moving
  `get.k3s.io` one) and must match `K3S_INSTALLER_SHA256`; update both
  when bumping the version
- **Node name:** `lima-k3s`
- **Service:** `systemd` unit `k3s` inside the VM

The VM provides the Linux kernel features K3s needs (cgroups, network
namespaces, iptables). K3s uses its own embedded containerd — Docker is
not required inside the VM.

## How kubectl Connects to K3s

The Mac's `kubectl` connects to the K3s API server through Lima's port
forwarding:

1. K3s listens on port **6443** inside the VM.
2. Lima forwards guest port 6443 to `127.0.0.1:6443` on the Mac.
3. The Mac's kubeconfig (`~/.kube/config`) has a context `k3s-lab`
   pointing to `https://127.0.0.1:6443`.

```
Mac kubectl  ──→  127.0.0.1:6443  ──→  Lima port-forward  ──→  VM K3s API :6443
```

The kubeconfig was copied from `/etc/rancher/k3s/k3s.yaml` inside the VM.
Its server address, `https://127.0.0.1:6443`, already works from the Mac
thanks to Lima's port forwarding, so only the context name was changed to
`k3s-lab`.

Every script in `scripts/` runs `kubectl`/`helm` with
`--context k3s-lab` explicitly, so it never acts on another cluster just
because kubectl's *current* context points elsewhere (Docker Desktop,
a work cluster, ...). To use a different context name:

```sh
KUBE_CONTEXT=my-context make argocd-status
```

To (re)create the context after rebuilding the VM (the new file is listed
first in `KUBECONFIG`, so its entries win over stale ones of the same name):

```sh
new=$(mktemp)
limactl shell k3s -- sudo cat /etc/rancher/k3s/k3s.yaml | sed 's/: default$/: k3s-lab/' > "$new"
KUBECONFIG="$new:$HOME/.kube/config" kubectl config view --flatten > "$new.merged" \
  && mv "$new.merged" "$HOME/.kube/config" && chmod 600 "$HOME/.kube/config"
rm -f "$new"
kubectl config use-context k3s-lab
```

## How to Check the Cluster

```sh
# Cluster info
kubectl cluster-info

# Nodes
kubectl get nodes

# All pods across all namespaces
kubectl get pods -A

# K3s system pods (should all be Running)
kubectl get pods -n kube-system

# Via Makefile (runs commands inside the VM)
make k3s-status
```

## How to Start / Stop K3s

```sh
# Start the K3s service inside the VM
make k3s-start

# Stop the K3s service inside the VM
make k3s-stop

# Check status
make k3s-status
```

Stopping the VM (`make vm-stop`) also stops K3s. Starting the VM
(`make vm-start`) does not automatically start K3s — run `make k3s-start`
afterwards.

## Troubleshooting

### kubectl cannot connect

```sh
# Check if the VM is running
make vm-status

# Check if K3s service is active inside the VM
limactl shell k3s -- sudo systemctl status k3s

# Check K3s logs
limactl shell k3s -- sudo journalctl -u k3s -f
```

### Node not Ready

```sh
# Check node conditions
kubectl describe node lima-k3s

# Check K3s service logs for errors
limactl shell k3s -- sudo journalctl -u k3s --no-pager -n 100
```

### Pods stuck in Pending

```sh
# Check if the default storage class exists (local-path provisioner)
kubectl get sc

# Check local-path-provisioner pod
kubectl get pods -n kube-system -l app=local-path-provisioner
```

### Pods stuck in ContainerCreating

```sh
# Check events for the namespace
kubectl get events --sort-by='.lastTimestamp' -A

# Check if containerd is running
limactl shell k3s -- sudo systemctl status k3s-containerd
```

### Reset K3s (nuclear option)

If the cluster is in a bad state and you want to start fresh:

```sh
# Uninstall K3s (removes all workloads and data)
limactl shell k3s -- sudo /usr/local/bin/k3s-uninstall.sh

# Reinstall K3s (pinned version, installed inside the VM)
make k3s-start
```

> Do **not** use `limactl shell k3s -- curl -sfL https://get.k3s.io | sh -`:
> the `| sh -` part runs on the **Mac**, not in the VM, so it would execute
> the K3s installer on macOS. `make k3s-start` downloads the pinned
> installer on the Mac, verifies its sha256 there, and runs it inside the VM.

> **Warning:** This deletes all pods, services, and data stored in the
> cluster. Use only when you want a completely clean slate.
