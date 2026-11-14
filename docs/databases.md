# Databases (PostgreSQL, MongoDB, Redis)

## What Each Database Is Used For

| Database | Image | Used for |
|----------|-------|----------|
| **PostgreSQL** | `postgres:17-alpine` | Relational (SQL) data: structured tables, joins, transactions. The go-to choice for a future application backend that needs real SQL. |
| **MongoDB** | `mongo:8.0` | Document (JSON/BSON) data: flexible, evolving schemas and quick prototyping without migrations. |
| **Redis** | `redis:7.4-alpine` | In-memory key-value store: caching, sessions, lightweight queues/locks. Runs with append-only-file (AOF) persistence in this lab so data survives restarts. |

> **Status: deployed** in the lab cluster with password authentication
> (`make databases-install`, 2026-11-15). The earlier no-auth version
> (applied 2026-10-04) was removed together with its throwaway data — see
> [Upgrading from the No-Auth Setup](#upgrading-from-the-no-auth-setup). There is no operator and no replica/HA
> setup — this is a small local learning environment. The manifests are
> exercised end to end in a throwaway cluster by `make test-e2e`.

## Where the Kubernetes Configuration Is Located

```text
kubernetes/
└── databases/
    ├── kustomization.yaml    # `kubectl apply -k` entry point (orders the namespace first)
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

Each database is exactly three simple objects (plus a credentials
`Secret` that is generated locally and never committed — see below):

- **Deployment** (1 replica) — runs the container, sets resource
  requests/limits, readiness/liveness probes, mounts the volume. The
  rollout strategy is `Recreate`, so the old pod always releases the
  `ReadWriteOnce` volume before its replacement starts. Containers run
  as the image's unprivileged user (no root, all capabilities dropped,
  no privilege escalation, `RuntimeDefault` seccomp) and get no
  Kubernetes API token.
- **Service** (ClusterIP) — stable in-cluster DNS name and port.
- **PersistentVolumeClaim** (1 GiB, `local-path`) — durable storage.

## How to Deploy

```sh
make databases-install     # idempotent — safe to re-run
make databases-status      # workloads, pods, services, volumes
make databases-password    # print the credentials
```

`make databases-install` (`scripts/databases-install.sh`):

1. Generates three random 32-character passwords once into
   `secrets/databases.env` (gitignored, mode `600`) and reuses them on
   every re-run.
2. Creates/updates the Secrets `postgres-credentials`,
   `mongodb-credentials` and `redis-credentials` in the `databases`
   namespace (values go through private temp files, never the command
   line).
3. Applies `kubernetes/databases/` with `kubectl apply -k` and waits for
   the three rollouts.

Applying the manifests without the script (`kubectl apply -k
kubernetes/databases/`, or an Argo CD Application) works too, but the pods
stay in `CreateContainerConfigError` until the three Secrets exist.

Because this repo is already GitOps-based, the same manifests can later
be deployed by pointing an **Argo CD Application** at
`kubernetes/databases/` instead of running the script — the Secrets then
need to come from a secret manager (e.g. Sealed Secrets or External
Secrets), never from Git.

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

To reach a database from the Mac, use port-forwarding:

```sh
kubectl port-forward -n databases svc/postgres 5432:5432
kubectl port-forward -n databases svc/mongodb 27017:27017
kubectl port-forward -n databases svc/redis 6379:6379
```

### Credentials

| Database | User | Auth |
|----------|------|------|
| PostgreSQL | `postgres` (database `lab`) | password, `scram-sha-256` |
| MongoDB | `root` (`authSource=admin`) | password (SCRAM), `--auth` enabled |
| Redis | default user | `requirepass` |

`make databases-password` prints them. Example connections after
`kubectl port-forward` (see above):

```sh
PGPASSWORD=... psql -h 127.0.0.1 -U postgres -d lab
mongosh "mongodb://root:...@127.0.0.1:27017/?authSource=admin"
REDISCLI_AUTH=... redis-cli -h 127.0.0.1
```

Applications in the cluster should read the password from the
corresponding Secret (`secretKeyRef`) rather than copying it.

### Rotating a Password

PostgreSQL and MongoDB only read their initial credentials when the data
directory is empty. To rotate, change the password **inside** the
database first (`ALTER USER postgres PASSWORD '...'` /
`db.changeUserPassword("root", "...")` / Redis needs no step — it reads
the config on start), update the value in `secrets/databases.env`, then
re-run `make databases-install` and restart the pod:

```sh
kubectl -n databases rollout restart deploy/postgres deploy/mongodb deploy/redis
```

### Upgrading from the No-Auth Setup

Earlier versions of these manifests ran PostgreSQL with
`POSTGRES_HOST_AUTH_METHOD=trust` and MongoDB/Redis without
authentication. If you ever applied them, the existing volumes keep that
state: PostgreSQL's `pg_hba.conf` still says `trust` and MongoDB has no
users, so new passwords would be **silently ignored**.
`make databases-install` detects this (volumes present, no saved
credentials) and stops. Either:

- **Throwaway data:** delete the old deployment and volumes, then install:
  ```sh
  kubectl delete -k kubernetes/databases/   # deletes the PVCs = deletes the data
  make databases-install
  ```
- **Keep data:** dump it first (`pg_dumpall`, `mongodump`, Redis
  `BGSAVE`), recreate as above, and restore.

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
- TLS between clients and databases
- NetworkPolicies (any pod in the cluster can reach the Services; the
  passwords are the access control)
- Monitoring/exporters

All of that can be layered on later; this milestone is the simplest
possible correct starting point.

## Verify After Deploying

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
