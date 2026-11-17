# GitOps for an External Application Repository

## Status

**Configuration only.** This document and the manifests under
[`kubernetes/argocd/applications/`](../kubernetes/argocd/applications/)
and [`kubernetes/kargo/`](../kubernetes/kargo/) prepare *this*
infrastructure repository to deploy a future application that lives in a
**separate** Git repository (`hello-devops`).

Nothing here has been applied, installed, or started. The application
repository URL and branch are resolved
(`https://github.com/CharbelKallas/hello-devops.git`, `master`); the
local container registry address is still a documented placeholder
(`<LOCAL_REGISTRY_URL>`), and the registry itself does not exist yet.

## Why the Application and the Infrastructure Live in Separate Repositories

Two Git repositories are planned:

| Repository | Status | Holds |
|---|---|---|
| `local-server` (this repo) | exists | the platform everything runs on |
| `hello-devops` | not created yet | one application |

Reasons for the split:

1. **Different lifecycles.** Application code changes many times a day;
   VMs, K3s, databases, and monitoring change rarely. Mixing them makes
   both histories noisier and releases harder to reason about.
2. **Different CI and credentials.** The application's GitHub Actions
   builds and pushes a container image to the local registry, so it needs
   push credentials. This repository must never need them — nothing
   here builds or pushes images. Each repo's CI can hold only the
   secrets it actually uses (least privilege).
3. **Different blast radius.** A bad merge in `hello-devops` can break
   one application. A bad merge here can break the VM, the cluster, the
   databases, or monitoring for everything.
4. **Different audiences.** Application developers work in the app repo
   without touching platform configuration; infrastructure changes get
   reviewed as infrastructure.
5. **Clean promotion history.** Kargo commits the promoted image digest
   into the application repository on every promotion, so *"what version
   ran in which environment, when"* stays with the application's own
   history instead of polluting the infrastructure's.
6. **Argo CD and Kargo are multi-repo by design.** An Argo CD
   `Application`'s `source.repoURL` can point at any Git repository, and
   Kargo promotion steps can clone and push any Git repository. No
   submodules, no vendored copies, no shared code — the only coupling is
   a handful of URLs (the placeholders below) and a small directory
   contract in the app repo.

## Who Owns What

| Concern | Owning repository | Notes |
|---|---|---|
| Application source code | `hello-devops` | never copied into this repo |
| Dockerfile / image build | `hello-devops` | built by the app repo's CI |
| Application Kubernetes manifests (Deployment, Service, Kustomize overlays) | `hello-devops` | rendered by Argo CD, owned by the app |
| Application GitHub Actions (build & push container image) | `hello-devops` | needs registry push credentials |
| Argo CD `Application` definitions | **this repo** | deployment configuration: declares *which* repo/path deploys *where* |
| Kargo promotion configuration (`Project`, `Warehouse`, `Stage`) | **this repo** | promotion policy is platform configuration |
| Infrastructure/platform configuration (VM, K3s, databases, monitoring, Argo CD, Kargo installs, scripts, docs) | **this repo** | the existing responsibility of this repo |

The rule of thumb: **the app repo answers "how is the application built
and what does it need"; this repo answers "what runs on the platform and
how does it get promoted."**

## What This Repository Adds for the Application

```text
kubernetes/
├── argocd/
│   ├── projects/
│   │   ├── hello-devops.yaml           # AppProject: limits what the app repo may deploy
│   │   └── hello-devops-namespaces.yaml # the two destination namespaces (owned here)
│   └── applications/
│       ├── hello-devops-dev.yaml       # Argo CD Application → <app repo>/dev
│       └── hello-devops-staging.yaml   # Argo CD Application → <app repo>/staging
└── kargo/
    ├── project.yaml                    # Kargo Project "hello-devops" (namespace + RBAC)
    ├── warehouse.yaml                  # watches the local registry for new images
    ├── stage-dev.yaml                  # dev Stage: writes image digest to <app repo>/dev
    └── stage-staging.yaml              # staging Stage: writes digest to <app repo>/staging
```

Each file carries a header comment stating its purpose, its placeholders,
and that it is not applied. No application Deployment/Service manifests,
no Dockerfile, no workflows, no application source live here — those are
the app repo's job.

## The Intended Flow (future)

```text
hello-devops (GitHub)
        │  push
        ▼
GitHub Actions          build image, push <LOCAL_REGISTRY_URL>/hello-devops:latest
        │
        ▼
Local container registry        (local only — no ECR, no AWS, no LocalStack)
        │  new digest discovered
        ▼
Kargo                     Warehouse → Freight → Stage "dev" → Stage "staging"
        │  each promotion commits the digest into the app repo (dev/, staging/)
        ▼
Argo CD                   Applications defined in THIS repo, automated sync
        │
        ▼
K3s                       namespaces hello-devops-dev / hello-devops-staging
        │
        ▼
hello-devops application running
```

Step by step:

1. A push to `hello-devops` triggers its GitHub Actions workflow, which
   builds the image and pushes `latest` to the local registry.
2. The Kargo `Warehouse` (this repo) polls that registry, notices the new
   digest, and produces a piece of `Freight`.
3. You promote the Freight into the `dev` `Stage`. Kargo runs four steps
   (clone → `kustomize-set-image` → commit → push) that write the digest
   into `<app repo>/dev/`.
4. The Argo CD `Application` `hello-devops-dev` (defined in this repo)
   sees the Git commit and, with automated sync enabled, applies the
   rendered manifests into `hello-devops-dev` on K3s.
5. The same promotion into the `staging` `Stage` writes
   `<app repo>/staging/`; `hello-devops-staging` syncs the same way.

Kargo never touches the cluster; Argo CD never builds images; this
repository never contains application code.

## Blast Radius: the `hello-devops` AppProject

Both Applications use a dedicated Argo CD `AppProject`
([`kubernetes/argocd/projects/hello-devops.yaml`](../kubernetes/argocd/projects/hello-devops.yaml))
instead of the built-in `default` project. With automated sync, whatever is
committed to the application repository is applied to the cluster, so the
project is the security boundary:

| Restriction | Value |
|---|---|
| Allowed source repositories | `https://github.com/CharbelKallas/hello-devops.git` only |
| Allowed destinations | namespaces `hello-devops-dev`, `hello-devops-staging` on this cluster |
| Allowed cluster-scoped kinds | **none** — not even `Namespace` |
| Denied namespaced kinds | `ResourceQuota`, `LimitRange`, `NetworkPolicy`, and `Endpoints`/`EndpointSlice` (hand-wired endpoints could point a Service at pods in other namespaces, e.g. the databases, and publish them on a NodePort that Lima forwards to the Mac) |
| Pod Security (on the two namespaces) | `restricted` enforced (policy pinned to v1.36): no privileged, root, `hostPath`, host network/PID |

Under `default`, anyone able to push to `hello-devops` (or its CI) could
deploy `ClusterRoleBinding`s, CRDs, admission webhooks, or workloads into
`kube-system` — full control of the cluster.

`Namespace` is deliberately not allowed either, even though that means the
Applications cannot use Argo CD's `CreateNamespace=true` (which Argo CD
treats as deploying a `Namespace` and therefore requires the kind to be
whitelisted). Whitelisting it would let the application repository commit a
manifest for *any* existing namespace — say `kube-system` — relabel it
(e.g. relax its pod-security labels), and, because `prune` is on, delete it
once the manifest is removed again. Instead, **this repository owns the two
destination namespaces**
([`hello-devops-namespaces.yaml`](../kubernetes/argocd/projects/hello-devops-namespaces.yaml)),
applied together with the project.

The project limits *which kinds* the repository may deploy; Pod Security
limits *what its Pods may do*. Without it, a single privileged Pod with a
`hostPath` mount of `/` would give root on the K3s node — including the
cluster-admin kubeconfig — despite every AppProject restriction. Both
namespaces are therefore labelled
`pod-security.kubernetes.io/enforce: restricted`; hello-devops's
Deployment already meets that profile.

The end-to-end test (`make test-e2e`) checks all of this against a real
Argo CD: an Application in this project targeting `kube-system` is
rejected; asking it to create a `Namespace` is refused and no namespace
appears; the real `hello-devops-dev` Application syncs from the
application repository into the infra-owned namespace and its pods are
admitted; and a privileged `hostPath` pod in that namespace is rejected.

## Placeholders to Replace

| Placeholder | Meaning | Files |
|---|---|---|
| `<HELLO_DEVOPS_GIT_REPOSITORY_URL>` | Clone URL of the future `hello-devops` repository | both files in `kubernetes/argocd/applications/`, `kubernetes/argocd/projects/hello-devops.yaml`, `stage-dev.yaml`, `stage-staging.yaml` |
| `<HELLO_DEVOPS_GIT_REPOSITORY_BRANCH>` | Branch holding the `dev/` and `staging/` paths (commonly `main`; `hello-devops` uses `master`) | same four files |
| `<LOCAL_REGISTRY_URL>` | Base address of the local container registry, including port, no trailing slash (example form: `localhost:5000`) | `warehouse.yaml`, `stage-dev.yaml`, `stage-staging.yaml` |

The three values must be kept consistent: `imageRepo` in both Stage files
must match the Warehouse's image `repoURL` exactly (Kargo resolves the
Freight image by repository URL), and the repository URL/branch in the
Stage files must match the Argo CD Applications.

**Replacement status:** the repository URL and branch are now resolved
in all four files
(`https://github.com/CharbelKallas/hello-devops.git`, branch `master`).
Only `<LOCAL_REGISTRY_URL>` remains to be replaced — here in
`warehouse.yaml`, `stage-dev.yaml`, `stage-staging.yaml`, and in the
application repository (`base/deployment.yaml`, `dev/`, `staging/`).
If the repository URL ever changes, change it in the AppProject's
`sourceRepos` too, or Argo CD will refuse to sync.

## Expected Shape of the Future `hello-devops` Repository

This is the contract this infrastructure assumes (owned entirely by the
app repo — nothing below is created here):

```text
hello-devops/
├── .github/workflows/        # CI: build image, push :latest to local registry
├── Dockerfile                # application image build
├── src/                      # application source code
├── base/                     # shared manifests
│   ├── deployment.yaml       # image: <LOCAL_REGISTRY_URL>/hello-devops:<any-tag>
│   ├── service.yaml
│   └── kustomization.yaml
├── dev/
│   └── kustomization.yaml    # resources: [../base] — Kargo updates images[] here
└── staging/
    └── kustomization.yaml    # resources: [../base] — Kargo updates images[] here
```

Contracts that matter:

- `dev/` and `staging/` must exist and contain a `kustomization.yaml` —
  those are the paths Argo CD points at and Kargo writes into.
- The base Deployment's image name must be exactly
  `<LOCAL_REGISTRY_URL>/hello-devops` (tag arbitrary), because
  `kustomize-set-image` matches on the full repository name when
  rewriting the digest.
- CI must push the `latest` tag on every build (the Warehouse's
  `Digest` selection strategy tracks it) and should filter on paths such
  as `src/**`, so Kargo's own promotion commits do not retrigger builds.

## How the Two Repositories Connect

- **This repo → `hello-devops`:** three references only — the Argo CD
  Applications' `repoURL`/`targetRevision`, the Kargo Stages' `vars`
  (used by `git-clone`/`git-push`), and the path contract
  (`dev/`, `staging/`).
- **`hello-devops` → this repo:** nothing. The app repo never references
  the infrastructure repo; it just provides source code, a Dockerfile,
  manifests, and CI.
- **Credentials:** if `hello-devops` is private, two git-credential
  `Secret`s are needed later (Kargo repository credentials in the
  `hello-devops` namespace; an Argo CD repository `Secret` in the
  `argocd` namespace). Both are cluster `Secret`s, never committed —
  follow the gitignored `secrets/` pattern of this repo and Kargo's
  [Managing Secrets](https://docs.kargo.io/user-guide/security/managing-secrets)
  guide.

## Future Setup Sequence (deliberately not executed)

All steps below belong to later milestones; this change stops at the
configuration above.

1. Create the `hello-devops` repository with the layout contract above.
2. Run a local container registry reachable from both the Mac and the
   K3s cluster (e.g. a `registry:2` container or a NodePort service) —
   design/installation is a future infrastructure decision.
3. Add the application's GitHub Actions workflow: build → push
   `<LOCAL_REGISTRY_URL>/hello-devops:latest` (path-filtered).
4. Replace the placeholders in the five files listed above.
5. If the repository is private: add the two credential `Secret`s.
6. Apply the Kargo configuration, in order (cluster must be running):
   ```sh
   kubectl apply -f kubernetes/kargo/project.yaml      # creates the namespace first
   kubectl apply -f kubernetes/kargo/warehouse.yaml
   kubectl apply -f kubernetes/kargo/stage-dev.yaml
   kubectl apply -f kubernetes/kargo/stage-staging.yaml
   ```
7. Apply the Argo CD AppProject and the two destination namespaces, then
   the Applications that use them:
   ```sh
   kubectl apply -f kubernetes/argocd/projects/      # AppProject + namespaces
   kubectl apply -f kubernetes/argocd/applications/
   ```
8. Verify and promote (see commands below).

## Deliberately Not Included

- Application source code, Dockerfile, application manifests, or
  application GitHub Actions — they belong to `hello-devops`.
- The local container registry itself (nothing installed/started).
- LocalStack, ECR, or any AWS dependency — the flow is fully local.
- Filled-in credentials or committed `Secret`s.
- Any `kubectl apply`, install, start, commit, or push — this milestone
  is configuration and documentation only.

## Later: Verification (for reference)

```sh
# Kargo objects exist once applied (namespace hello-devops created by Project)
kubectl get project,warehouse,stage -n hello-devops

# Argo CD Applications appear in the UI (NodePort 30080) once applied
kubectl get applications -n argocd

# After the first Freight exists: promote dev -> staging in the Kargo UI
# (NodePort 30090) or via the Kargo CLI.
```

See [argocd.md](argocd.md) and [kargo.md](kargo.md) for how both tools
are installed and accessed in this lab.
