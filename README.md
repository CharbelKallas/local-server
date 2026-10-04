# Local DevOps Lab

A local DevOps/cloud-native learning lab running on an Apple Silicon Mac (M2 Max, 32 GB RAM).

## Architecture Overview

| Component | Where it runs | Purpose |
|-----------|---------------|---------|
| **K3s** | Linux VM | Lightweight Kubernetes cluster |
| **Ollama** | Native macOS | Local LLM inference |
| **Docker** | Native macOS | Container runtime (used only where appropriate) |
| **LocalStack** | Docker | Local AWS service emulation |
| **Argo CD** | K3s | GitOps continuous delivery |
| **Kargo** | K3s | GitOps promotion orchestration (dev → staging) |
| **PostgreSQL** | K3s | Relational database (SQL) — manifests prepared, not deployed |
| **MongoDB** | K3s | Document database (JSON) — manifests prepared, not deployed |
| **Redis** | K3s | Cache / key-value store — manifests prepared, not deployed |
| **Prometheus** | K3s | Metrics collection |
| **Grafana** | K3s | Observability dashboards |
| **Loki** | K3s | Log aggregation |

## Repository Structure

```
local-server/
├── README.md
├── Makefile
├── .gitignore
├── vm/               # Linux VM configuration (Lima)
├── kubernetes/       # Kubernetes manifests (databases/)
├── scripts/          # Automation and utility scripts
└── docs/             # Documentation
```

## Why a Linux VM Is Needed

K3s is a Linux-only Kubernetes distribution. It needs a real Linux kernel for
cgroups, network namespaces, iptables, and other kernel features that macOS
does not provide. A Linux VM gives us a genuine Linux environment on the Mac,
which is required for K3s and the tools that will run on top of it.

## How the VM Works

The VM is managed by [Lima](https://lima-vm.io/) (Linux virtual Machines),
a free, open-source tool that runs Linux VMs on macOS using Apple's
Virtualization.framework. It is lightweight, scriptable, and already
installed on this machine.

- **Instance name:** `k3s` (matches its purpose — it will run K3s)
- **OS:** Ubuntu 24.04 Server (arm64)
- **Resources:** 4 CPUs, 6 GiB RAM, 40 GiB disk (conservative for a 32 GB host)
- **Port forwarding:** guest ports 6443 (K3s API) and 30000–32767 (NodePort
  range) are forwarded to the same ports on the macOS host
- **Configuration file:** `vm/k3s.yaml`

## Getting Started

This repository is a foundation. Components will be added incrementally.

Run `make help` to see available commands.

### Start the VM

```sh
make vm-start
```

On first run this creates the VM from `vm/k3s.yaml` (downloads the Ubuntu
cloud image, may take a few minutes). On later runs it simply starts the
existing VM.

### Stop the VM

```sh
make vm-stop
```

### Check VM status

```sh
make vm-status
```

### Connect to the VM

```sh
make vm-ssh
```

This opens an interactive shell on the VM. You can also run one-off commands:

```sh
scripts/vm-ssh.sh "uname -a"
```

### K3s Cluster

K3s is already installed and running inside the VM. The Mac's `kubectl`
connects to it via Lima's port forwarding (guest 6443 → host 127.0.0.1:6443).

```sh
# Check cluster status
make k3s-status

# Start K3s (if not running)
make k3s-start

# Stop K3s
make k3s-stop

# Verify kubectl works
kubectl get nodes
kubectl get pods -A
```

See [docs/k3s.md](docs/k3s.md) for full documentation.

### Argo CD

Argo CD is installed in the K3s cluster (namespace `argocd`) from the
official stable manifests. The UI is exposed on NodePort 30080, forwarded
by Lima to `https://localhost:30080` on the Mac (no ingress controller).

```sh
# Install / re-run (idempotent)
make argocd-install

# Pods + services + UI address
make argocd-status

# Initial admin password (username: admin)
make argocd-password

# Open the UI in the browser
make argocd-ui
```

See [docs/argocd.md](docs/argocd.md) for full documentation.

### Kargo

Kargo is installed in the K3s cluster (namespace `kargo`) from the official
Helm chart, together with its `cert-manager` prerequisite. It is the
**promotion** layer that decides which version belongs in which environment;
Argo CD still does the deploying. The UI/API is exposed on NodePort 30090 →
`https://localhost:30090` (username `admin`).

```sh
# Install / re-run (idempotent; also installs cert-manager if missing)
make kargo-install

# Pods, workloads, services, CRDs, Helm release, cert-manager
make kargo-status

# Admin password (stored in the gitignored secrets/ directory)
make kargo-password
```

No `Project`/`Stage`/`Warehouse` objects exist yet — promotion workflows come
in a later step. See [docs/kargo.md](docs/kargo.md) for full documentation.

### Databases

Kubernetes manifests for **PostgreSQL**, **MongoDB** and **Redis** are
prepared under [`kubernetes/databases/`](kubernetes/databases/) — one
shared namespace (`databases`), and per database a Deployment (1 replica),
a ClusterIP Service, and a 1 Gi PersistentVolumeClaim on the K3s
`local-path` storage class. They are **configuration only: nothing has
been applied, installed, or started yet.**

```sh
# When deployment is wanted (cluster must be running):
kubectl apply -f kubernetes/databases/namespace.yaml
kubectl apply -R -f kubernetes/databases/

# Verify
kubectl get deploy,svc,pvc -n databases
```

Ports: PostgreSQL `postgres:5432`, MongoDB `mongodb:27017`, Redis
`redis:6379` (all ClusterIP, in-cluster only). See
[docs/databases.md](docs/databases.md) for usage, deployment details, and
how persistent storage works.

## Prerequisites

- Apple Silicon Mac (M2 Max, 32 GB RAM)
- [x] Linux VM for K3s (Lima — see `vm/k3s.yaml`)
- [x] K3s (lightweight Kubernetes — see `docs/k3s.md`)
- [ ] Docker Desktop or Colima
- [ ] Ollama
- [ ] LocalStack
- [x] Argo CD (GitOps CD — see `docs/argocd.md`)
- [x] Kargo (GitOps promotion — see `docs/kargo.md`)
- [ ] Databases: PostgreSQL / MongoDB / Redis (manifests ready, not deployed — see `docs/databases.md`)
- [ ] Prometheus / Grafana / Loki

## License

MIT
