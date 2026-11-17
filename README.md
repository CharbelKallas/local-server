# Local DevOps Lab

A local DevOps/cloud-native learning lab running on an Apple Silicon Mac (M2 Max, 32 GB RAM).

## Architecture Overview

| Component | Where it runs | Purpose |
|-----------|---------------|---------|
| **K3s** | Linux VM | Lightweight Kubernetes cluster |
| **Argo CD** | K3s | GitOps continuous delivery (deploys external application repos) |
| **Kargo** | K3s | GitOps promotion orchestration (dev → staging) |
| **PostgreSQL** | K3s | Relational database (SQL) — `make databases-install`, password auth |
| **MongoDB** | K3s | Document database (JSON) — `make databases-install`, password auth |
| **Redis** | K3s | Cache / key-value store — `make databases-install`, password auth |
| **Docker** | Native macOS | Container runtime (used for `make test-e2e`) |
| *Ollama* | Native macOS | Local LLM inference — *planned, not in this repo yet* |
| *Prometheus / Grafana / Loki* | K3s | Metrics, dashboards, logs — *planned, not in this repo yet* |

## Repository Structure

```
local-server/
├── README.md
├── Makefile
├── .gitignore
├── vm/               # Linux VM configuration (Lima)
├── kubernetes/       # Kubernetes manifests
│   ├── argocd/       #   Argo CD AppProject + Application definitions (external apps)
│   ├── databases/    #   PostgreSQL / MongoDB / Redis
│   └── kargo/        #   Kargo Project / Warehouse / Stage (promotion)
├── scripts/          # Automation scripts (shared helpers in scripts/lib.sh)
├── tests/            # lint, script unit tests, kind end-to-end test
├── .github/workflows # CI: runs all of the above on pushes to master and on PRs
└── docs/             # Documentation
```

## Two-Repository Design (Infrastructure vs. Application)

Application code does **not** live in this repository. The future
`hello-devops` application will live in its own separate Git repository;
this repository keeps only the platform plus the GitOps configuration
that points Argo CD and Kargo at it:

| Concern | Owning repository |
|---------|-------------------|
| Application source code, Dockerfile, application Kubernetes manifests, application GitHub Actions | `hello-devops` (external — not created yet) |
| Argo CD `Application` definitions, Kargo promotion configuration | `local-server` (this repo) |
| VM, K3s, databases, monitoring, Argo CD / Kargo, scripts, docs | `local-server` (this repo) |

Why separate: the two change at different cadences, their CI jobs need
different credentials (only the app's CI pushes images — this repo never
does), and a broken application merge must not be able to break the
platform (and vice versa). Argo CD and Kargo are multi-repo by design,
so the only coupling is a few documented placeholder URLs — no code is
shared. Full rationale, ownership table, placeholders, and the future
deployment flow: [docs/gitops.md](docs/gitops.md).

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
official manifests, pinned to a release (`v3.6.1`). The UI is exposed on
NodePort 30080, forwarded by Lima to `https://localhost:30080` on the Mac (no ingress controller).

Argo CD `Application` definitions (and a restricted `AppProject`) for the
future **external** application repository are prepared (**not applied**) under
[`kubernetes/argocd/applications/`](kubernetes/argocd/applications/) —
see [docs/gitops.md](docs/gitops.md).

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

`Project`/`Stage`/`Warehouse` objects for the future external application
are **prepared as configuration only** (placeholders, **not applied**)
under [`kubernetes/kargo/`](kubernetes/kargo/) — see
[docs/gitops.md](docs/gitops.md). See [docs/kargo.md](docs/kargo.md) for
full documentation.

### Databases

**PostgreSQL**, **MongoDB** and **Redis** live under
[`kubernetes/databases/`](kubernetes/databases/) — one shared namespace
(`databases`), and per database a Deployment (1 replica, non-root,
probes), a ClusterIP Service, and a 1 Gi PersistentVolumeClaim on the K3s
`local-path` storage class. All three require a password; the passwords
are generated locally into the gitignored `secrets/` directory and never
committed.

```sh
make databases-install     # generate credentials (once), create Secrets, deploy, wait
make databases-status
make databases-password
```

Ports: PostgreSQL `postgres:5432`, MongoDB `mongodb:27017`, Redis
`redis:6379` (all ClusterIP, in-cluster only). See
[docs/databases.md](docs/databases.md) for usage, credentials, rotation,
and how persistent storage works.

## Kube Context Safety

Every script talks to the cluster through the kubeconfig context
**`k3s-lab`** explicitly (`kubectl --context`, `helm --kube-context`), never
through whatever context happens to be current, so `make argocd-install`
cannot install into a different cluster by accident. Override with
`KUBE_CONTEXT=<name> make ...` if your context is named differently. See
[docs/k3s.md](docs/k3s.md).

## Tests

```sh
make lint       # shellcheck + kubeconform (strict) on all scripts/manifests
make test       # lint + unit tests for every script (stubbed kubectl/helm/limactl)
make test-e2e   # throwaway kind cluster: real installs + behaviour checks
```

`make lint` and `make test` need no cluster (they use local `shellcheck` /
`kubeconform` if installed, otherwise pinned Docker images).
`make test-e2e` needs Docker, `kind`, `kubectl`, `helm`, `openssl` and
`htpasswd`. It uses its **own** kubeconfig file, so it never touches
`~/.kube/config` or the Lima VM, and it deletes the cluster afterwards. It
verifies that each database rejects unauthenticated clients, accepts the
generated credentials, persists data across restarts and runs as non-root;
that Argo CD and Kargo install and are reachable with their passwords; and
that the GitOps manifests are accepted by the real CRDs (including that
the AppProject rejects deployments into `kube-system` and refuses
`Namespace` objects, while the real `hello-devops-dev` app still syncs);
and that privileged pods are rejected by Pod Security in the app and
database namespaces. Skip suites with
`E2E_SKIP="argocd kargo"`.

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs all three
on pushes to `master` and on pull requests (pushes to other branches without
a PR are not tested).

## Prerequisites

- Apple Silicon Mac (M2 Max, 32 GB RAM)
- [x] Linux VM for K3s (Lima — see `vm/k3s.yaml`)
- [x] K3s (lightweight Kubernetes — see `docs/k3s.md`)
- [ ] Docker Desktop or Colima
- [ ] Ollama
- [x] Argo CD (GitOps CD — see `docs/argocd.md`)
- [x] Kargo (GitOps promotion — see `docs/kargo.md`)
- [x] Databases: PostgreSQL / MongoDB / Redis (password auth, `make databases-install` — see `docs/databases.md`)
- [ ] Prometheus / Grafana / Loki
- [ ] External application repository `hello-devops` (not created yet — GitOps config prepared, see `docs/gitops.md`)

## License

MIT
