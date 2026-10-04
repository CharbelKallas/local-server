# K3s Cluster

## Where K3s Runs

K3s runs inside the Linux VM managed by Lima (instance name: `k3s`).

- **VM OS:** Ubuntu 24.04 LTS (arm64)
- **K3s version:** v1.36.5+k3s1
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

The kubeconfig was copied from `/etc/rancher/k3s/k3s.yaml` inside the VM
and the server address was changed from `https://127.0.0.1:6443` (which
is already correct for Lima's forwarding).

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

# Reinstall K3s
limactl shell k3s -- curl -sfL https://get.k3s.io | sh -
```

> **Warning:** This deletes all pods, services, and data stored in the
> cluster. Use only when you want a completely clean slate.
