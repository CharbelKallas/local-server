# Kargo

## What Kargo Does

Kargo is a **continuous promotion** layer for GitOps. It answers the question
*"which version of the app should run in which environment, and when does it
move up?"* — without custom CI scripts.

Kargo **never deploys anything itself**. It decides *what* should be deployed
by writing the desired version (image digest, chart version, git revision) to
Git, and Argo CD — already installed in this cluster — does the actual
deploying by syncing the cluster with Git.

Core concepts (only these matter for the `dev` → `staging` lab):

| Concept | Kind | Purpose |
|---------|------|---------|
| `Project` | `projects.kargo.akuity.io` | A namespace plus RBAC: one per application |
| `Warehouse` | `warehouses.kargo.akuity.io` | Watches sources (Git repo, image registry) for new versions |
| `Freight` | `freights.kargo.akuity.io` | An immutable bundle of artifacts (image + commit) found by a Warehouse |
| `Stage` | `stages.kargo.akuity.io` | One environment (`dev`, then `staging`); declares how Freight is promoted into it |
| `Promotion` | `promotions.kargo.akuity.io` | The act of advancing a specific Freight into a Stage |

Flow: `Warehouse` discovers a new image → produces `Freight` → `Freight` is
promoted into `dev` → (manual approval / verification) → promoted into
`staging`. Each promotion updates Git; Argo CD syncs from there.

## Where Kargo Runs

Kargo is installed in the existing K3s cluster, in its own namespace `kargo`,
using the official Helm chart (this is Kargo's standard installation method):

```sh
helm upgrade --install kargo oci://ghcr.io/akuity/kargo-charts/kargo \
  --namespace kargo --create-namespace \
  --version 1.12.1 \
  --set-string api.adminAccount.passwordHash=... \
  --set-string api.adminAccount.tokenSigningKey=... \
  --set api.service.type=NodePort \
  --set api.service.nodePort=30090 \
  --wait
```

> The password hash and token signing key are **mandatory** chart values with
> no defaults. `scripts/kargo-install.sh` generates them once and keeps them
> in `secrets/kargo-admin.env` (already gitignored), so re-runs are stable.

Installed components (all in namespace `kargo`):

| Component | Kind | Purpose |
|-----------|------|---------|
| `kargo-api` | Deployment | API server **+ web UI** (exposed on NodePort 30090) |
| `kargo-controller` | Deployment | Promotes Freight into Stages (writes to Git, watches Argo CD) |
| `kargo-management-controller` | Deployment | Manages Project namespaces and RBAC |
| `kargo-webhooks-server` | Deployment | Internal validating/mutating webhooks (TLS via cert-manager) |
| `kargo-external-webhooks-server` | Deployment | Webhooks for external callers (e.g. Git push events) — not configured yet |

Also installed:

- **11 CRDs** (`*.kargo.akuity.io`): `projects`, `warehouses`, `freights`,
  `stages`, `promotions`, `promotionrequests`, `promotiontasks`,
  `clusterpromotiontasks`, `clusterconfigs`, `projectconfigs`, `targets`
- **cert-manager v1.21.2** in namespace `cert-manager` — a **prerequisite** of
  Kargo's default configuration: it issues the self-signed TLS certificates
  used by the API server and webhook servers. Installed by
  `scripts/kargo-install.sh` only if missing; left untouched otherwise.
- **ClusterRoles** such as `kargo-controller-argocd`, which grants the Kargo
  controller access to Argo CD `Application` resources (see below).
- Two chart-default helper namespaces: `kargo-shared-resources` and
  `kargo-system-resources` (used for cluster-scoped resources that have no
  namespace of their own).

Deliberately **not** installed: no Argo Rollouts (the API server detects its
absence and disables that integration — see "expected log line" below), no
database, no ingress controller, no monitoring, no `Project`/`Stage`/
`Warehouse` objects yet.

## How to Access It (UI / API)

The `kargo-api` Service is exposed as **NodePort 30090** (HTTPS). Lima
forwards guest NodePorts to the same ports on the Mac (see `vm/k3s.yaml`), so
the UI is reachable directly on the host:

```
https://localhost:30090
```

- **Username:** `admin`
- **Password:** `make kargo-password` (read from `secrets/kargo-admin.env`)
- The certificate is self-signed — your browser will warn; that is expected.

Alternative without NodePort (from `helm notes`):

```sh
kubectl port-forward -n kargo svc/kargo-api 3000:443
# then open https://localhost:3000
```

The Kargo CLI is **not** installed (optional, future step):

```sh
kargo login https://localhost:30090 --admin --insecure-skip-tls-verify
```

## How to Check Its Status

```sh
# The primary health check: all pods should be Running and 1/1 Ready
kubectl get pods -n kargo

# Pods + workloads + services + CRDs + Helm release + cert-manager in one shot
make kargo-status

# Workloads should all be READY 1/1
kubectl get deploy -n kargo

# The 11 Kargo CRDs must be registered
kubectl get crd -o name | grep kargo.akuity.io

# Helm release status (should be "deployed", chart 1.12.1)
helm list -n kargo

# UI responds (expect: 200)
curl -sk -o /dev/null -w "%{http_code}\n" https://localhost:30090/
```

Healthy output of `kubectl get pods -n kargo`:

```
NAME                                              READY   STATUS    RESTARTS   AGE
kargo-api-...                                     1/1     Running   0          ...
kargo-controller-...                              1/1     Running   0          ...
kargo-external-webhooks-server-...                1/1     Running   0          ...
kargo-management-controller-...                   1/1     Running   0          ...
kargo-webhooks-server-...                         1/1     Running   0          ...
```

There is also a `kargo-garbage-collector` CronJob (not a pod — it only runs on
schedule), so do not expect it in the pod list.

## How It Will Eventually Work With Argo CD

Argo CD and Kargo are complementary, not competing:

| | Argo CD | Kargo |
|---|---------|-------|
| Question it answers | "Does the cluster match Git?" | "Which version belongs in which environment?" |
| Acts by | Syncing the cluster from Git | Writing the new version to Git (promoting) |
| Trigger | Git changes | Promotion events (manual/auto, with guardrails) |

Planned shape for this lab (envs: `dev`, `staging` — **not created yet**):

```text
Warehouse  ──finds new image──▶  Freight (immutable artifact bundle)
                                     │
                                     ▼  promote
                              Stage "dev"     ──writes image ref to git/dev/──▶  Argo CD App "app-dev"     ──syncs──▶ cluster (dev)
                                     │  (manual approval)
                                     ▼  promote
                              Stage "staging" ──writes image ref to git/staging/─▶ Argo CD App "app-staging" ──syncs──▶ cluster (staging)
```

Concretely, that means:

1. One **Argo CD `Application` per environment**, each pointing at its own
   path/branch in the environment repo (`dev`, `staging`).
2. One Kargo **`Project`** containing a `Warehouse` (image + git sources) and
   two `Stage`s (`dev`, `staging`). The second `Stage` references the first,
   so Freight flows dev → staging.
3. Promoting a `Stage` makes Kargo commit the new image digest to that
   environment's Git path. **Argo CD notices the Git change and syncs** —
   Kargo does not touch the workloads in the cluster.
4. The chart already enabled Kargo's Argo CD integration by default
   (`controller.argocd.integrationEnabled=true`, namespace `argocd`): the
   `kargo-controller-argocd` ClusterRole lets the Kargo controller read Argo
   CD `Application` health/sync state, so a Stage's health reflects reality
   and Argo-CD-based promotion mechanisms can be used later.

Kargo's promotion itself only needs Git credentials (a `Secret` in the future
`Project`) — no agent inside Argo CD.

## Install / Re-run

```sh
# Install (idempotent — safe to re-run; also installs cert-manager if absent)
make kargo-install

# Show status + UI address
make kargo-status

# Print the admin password
make kargo-password
```

Pinned versions (change them in `scripts/kargo-install.sh`):

| Component | Version |
|-----------|---------|
| Kargo Helm chart / app | `1.12.1` / `v1.12.1` |
| cert-manager | `v1.21.2` |

## Troubleshooting

```sh
# Pod logs
kubectl -n kargo logs deploy/kargo-controller --tail=50
kubectl -n kargo logs deploy/kargo-api --tail=50

# Events
kubectl get events -n kargo --sort-by='.lastTimestamp'

# Helm release state (failed/pending-install, etc.)
helm status kargo -n kargo
helm list -n kargo

# Webhook/TLS problems are almost always cert-manager problems
kubectl get pods -n cert-manager
kubectl get certificate -n kargo

# kubectl cannot reach the cluster?
make k3s-status        # see docs/k3s.md
```

Notes:

- The API log line `Argo Rollouts integration was enabled, but no Argo
  Rollouts CRDs were found. Proceeding without Argo Rollouts integration.` is
  **expected** — Argo Rollouts is optional and not installed in this lab.
- If pods stay `ContainerCreating`/`Pending` with webhook errors, wait a few
  seconds for the cert-manager-issued certificates; re-run `make
  kargo-install` if it persists.
- Re-running `make kargo-install` reuses the credentials in
  `secrets/kargo-admin.env`; delete that file only if you want to rotate the
  admin password.
