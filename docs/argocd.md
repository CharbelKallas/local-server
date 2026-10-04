# Argo CD

## Where Argo CD Runs

Argo CD is installed into the existing K3s cluster, in its own namespace
`argocd`, using the official stable manifests (the normal Kubernetes
installation method, non-HA):

```sh
kubectl apply --server-side -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

> Server-side apply is required because the `applicationsets` CRD is
> larger than the 256 KiB annotation limit of client-side `kubectl apply`.

Installed components (all in namespace `argocd`):

| Component | Kind | Purpose |
|-----------|------|---------|
| `argocd-server` | Deployment | UI + API |
| `argocd-repo-server` | Deployment | Git repository access |
| `argocd-application-controller` | StatefulSet | Applies and syncs applications |
| `argocd-applicationset-controller` | Deployment | ApplicationSet templating |
| `argocd-dex-server` | Deployment | SSO (not configured yet) |
| `argocd-redis` | Deployment | Cache (in-cluster only, not a database install) |
| `argocd-notifications-controller` | Deployment | Notifications (not configured yet) |

No ingress controller, no external database, no monitoring — deliberately
minimal.

## How to Access It

The `argocd-server` Service is exposed as **NodePort 30080** (https).
Lima forwards guest NodePorts to the same ports on the Mac
(see `vm/k3s.yaml`), so the UI is reachable directly on the host:

```
https://localhost:30080
```

- **Username:** `admin`
- **Password:** see below
- The certificate is self-signed — your browser will warn; that is expected.

```sh
# Open the UI in the browser
make argocd-ui
```

## Retrieve the Initial Admin Password

```sh
make argocd-password
```

This decodes the `argocd-initial-admin-secret` in the `argocd` namespace.
Equivalent raw command:

```sh
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Note: this secret is deleted after the first successful login. To reset a
lost password later:

```sh
kubectl -n argocd patch secret argocd-initial-admin-secret \
  -p '{"data":{"password":"'$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}')'"}}'
kubectl -n argocd rollout restart deploy/argocd-server
```

(or simply set a new password with `argocd account update-password` after
logging in with any valid credential).

## Verify Health

```sh
# All Argo CD pods should be Running and 1/1 Ready
kubectl get pods -n argocd

# Pods + services + UI address in one shot
make argocd-status

# Workloads should all be READY 1/1
kubectl get deploy,statefulset -n argocd

# UI responds
curl -sk -o /dev/null -w "%{http_code}\n" https://localhost:30080/
# expect: 200
```

Healthy output looks like:

```
NAME                                                READY   STATUS    RESTARTS   AGE
argocd-application-controller-0                     1/1     Running   0          ...
argocd-applicationset-controller-...                 1/1     Running   0          ...
argocd-dex-server-...                                1/1     Running   0          ...
argocd-notifications-controller-...                  1/1     Running   0          ...
argocd-redis-...                                     1/1     Running   0          ...
argocd-repo-server-...                               1/1     Running   0          ...
argocd-server-...                                    1/1     Running   0          ...
```

## Install / Re-run

```sh
# Install (idempotent — safe to re-run, also re-applies the NodePort patch)
make argocd-install
```

## Troubleshooting

```sh
# Pod logs
kubectl -n argocd logs deploy/argocd-server --tail=50
kubectl -n argocd logs deploy/argocd-applicationset-controller --tail=50

# Events
kubectl get events -n argocd --sort-by='.lastTimestamp'

# kubectl cannot reach the cluster?
make k3s-status        # see docs/k3s.md
```
