# Databases (PostgreSQL, MongoDB, Redis)

## What Each Database Is Used For

| Database | Image | Used for |
|----------|-------|----------|
| **PostgreSQL** | `postgres:17-alpine` | Relational (SQL) data: structured tables, joins, transactions. The go-to choice for a future application backend that needs real SQL. |
| **MongoDB** | `mongo:8.0` | Document (JSON/BSON) data: flexible, evolving schemas and quick prototyping without migrations. |
| **Redis** | `redis:7.4-alpine` | In-memory key-value store: caching, sessions, lightweight queues/locks. Runs with append-only-file (AOF) persistence in this lab so data survives restarts. |

> **Status: configuration only.** The manifests are written and validated,
> but nothing has been installed, applied, or started. There is no operator
> and no replica/HA setup — this is a small local learning environment.

## Where the Kubernetes Configuration Is Located

```text
kubernetes/
└── databases/
    ├── namespace.yaml        # one shared namespace: "databases"
    ├── postgres/
    │   ├── deployment.yaml   # workload: 1 replica, image, resources, volume mount
    │   ├── service.yaml      # ClusterIP :5432
    │   └── pvc.yaml          # 1Gi claim on the local-path StorageClass
    ├── mongodb/
    │   ├── deployment.yaml   # workload: 1 replica, image, resources, volume mount
    │   ├── service.yaml      # ClusterIP :27017
    │   └── pvc.yaml          # 1Gi claim on the local-path StorageClass
    └── redis/
        ├── deployment.yaml   # workload: 1 replica, AOF persistence, resources
        ├── service.yaml      # ClusterIP :6379
        └── pvc.yaml          # 1Gi claim on the local-path StorageClass
```

All three databases share a **single namespace** (`databases`). Separate
namespaces per database would add ceremony without a benefit at this
scale; the workloads still get their own Service DNS names, so nothing
is ambiguous.

Each database is exactly three simple objects:

- **Deployment** (1 replica) — runs the container, sets resource
  requests/limits, mounts the volume. The rollout strategy is
  `Recreate`, so the old pod always releases the `ReadWriteOnce`
  volume before its replacement starts.
- **Service** (ClusterIP) — stable in-cluster DNS name and port.
- **PersistentVolumeClaim** (1 GiB, `local-path`) — durable storage.

## How They Will Eventually Be Deployed

Nothing is deployed yet. When the cluster is running and deployment is
wanted, apply the namespace first, then everything else:

```sh
# 1. create the namespace
kubectl apply -f kubernetes/databases/namespace.yaml

# 2. apply all database manifests (recursive)
kubectl apply -R -f kubernetes/databases/

# 3. verify
kubectl get deploy,svc,pvc -n databases
kubectl get pods -n databases
```

> The namespace must be applied first: `kubectl` walks a directory
> alphabetically, so `mongodb/` would otherwise be processed before
> `namespace.yaml` and fail with "namespaces not found".

Because this repo is already GitOps-based, the same manifests can later
be deployed by pointing an **Argo CD Application** at
`kubernetes/databases/` instead of running `kubectl apply` by hand —
that is the intended long-term path (Argo CD deploys, Kargo promotes).

## Ports and Services

| Database | Service name | Type | Port | In-cluster address |
|----------|--------------|------|------|--------------------|
| PostgreSQL | `postgres` | ClusterIP | 5432 | `postgres.databases.svc.cluster.local:5432` |
| MongoDB | `mongodb` | ClusterIP | 27017 | `mongodb.databases.svc.cluster.local:27017` |
| Redis | `redis` | ClusterIP | 6379 | `redis.databases.svc.cluster.local:6379` |

Unlike the Argo CD (NodePort 30080) and Kargo (NodePort 30090) UIs, the
databases are **not** exposed with a NodePort or ingress — they are
reachable only from inside the cluster. Other pods connect using the
Service name, e.g. `postgres.databases.svc.cluster.local:5432`.

To reach a database from the Mac (once deployed), use port-forwarding:

```sh
kubectl port-forward -n databases svc/postgres 5432:5432
kubectl port-forward -n databases svc/mongodb 27017:27017
kubectl port-forward -n databases svc/redis 6379:6379
```

### Credentials (local lab defaults)

| Database | Access |
|----------|--------|
| PostgreSQL | database `lab`, user `postgres`, `trust` authentication (no password) |
| MongoDB | no authentication configured |
| Redis | no password configured |

Acceptable for a local lab that is never exposed beyond the cluster.
Before anything non-local, move credentials into `Secret`s (the
gitignored `secrets/` directory pattern) and enable real authentication.

## How Persistent Storage Works

K3s bundles the **local-path provisioner**, whose StorageClass
`local-path` is the cluster's default storage class (already referenced
in [k3s.md](k3s.md)). Every database PVC uses it explicitly via
`storageClassName: local-path`.

What happens when the databases are first deployed:

1. A pod starts and its PVC is *Pending* (no volume yet).
2. The provisioner creates a host directory on the node at
   `/var/lib/rancher/k3s/storage/<pv-name>` — a real directory on the
   VM's 40 GiB disk.
3. It wraps that directory in a `PersistentVolume`, binds it to the
   claim (`ReadWriteOnce`, 1 GiB requested), and the pod starts with
   the directory mounted:
   - PostgreSQL → `/var/lib/postgresql/data`
   - MongoDB → `/data/db`
   - Redis → `/data`
4. The database writes its files there, outside the container
   filesystem.

What this means in practice:

- **Data survives** pod restarts, pod recreation, image upgrades, and
  `make vm-stop` / `make vm-start` — it lives on the VM disk.
- **Data is lost** if the PVC/PV is deleted (reclaim policy `Delete`)
  or K3s is uninstalled/reset (see the "Reset K3s" section in
  [k3s.md](k3s.md)).
- **Node-local only:** `local-path` is a directory on the single node —
  no replication, no failover, no distributed storage. Intentional for
  this lab; `local-path` does not enforce the 1 GiB size (the data just
  has to fit on the VM's disk).
- **One pod at a time** per volume: single replica + `Recreate`
  strategy guarantees the volume is never mounted by two pods at once.

## What Is Deliberately Not Included

- Database operators (CloudNativePG, MongoDB Operator, Redis Operator)
- Replicas, clustering, high availability
- Distributed storage (Ceph/Longhorn/etc.)
- Backup/snapshot infrastructure
- TLS, Secrets, and auth hardening
- Probes and monitoring

All of that can be layered on later; this milestone is the simplest
possible correct starting point.

## Verify After Deploying (for later use)

```sh
# Workloads, services, claims
kubectl get deploy,svc,pvc -n databases

# Pod status
kubectl get pods -n databases

# Storage bound? (PVC becomes "Bound", one PV appears per claim)
kubectl get pvc -n databases
kubectl get pv                # PVs are cluster-scoped

# Logs
kubectl logs -n databases deploy/postgres --tail=20
kubectl logs -n databases deploy/mongodb --tail=20
kubectl logs -n databases deploy/redis --tail=20
```
