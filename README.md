# js-poc-csoc-bootstrap

Bootstraps profile-separated CSOC management clusters on Jetstream2 Magnum,
installs Argo CD, and hands controllers, RGD definitions, and selected fleet
instances to GitOps.

## CSOC environments

| Profile | Magnum ownership | Git sources | Fleet |
|---|---|---|---|
| `dev` (default) | Existing `js2-mgmt-cluster-2`; 1 × `m3.quad` control plane | bootstrap `master`, catalog/fleet `main` | CSOC Hello and `test-poc` |
| `prod` | Dormant `js2-csoc-prod`; immutable 3 × `m3.quad` control plane | coordinated `release/prod` branches | disabled |

Production is a template only: nothing creates it unless an operator explicitly
runs a Magnum provisioning target with `PROFILE=prod` after the coordinated
release branches exist.

## Quick start

```bash
make help              # list all targets
make container-build   # build the pinned management image
make bootstrap         # full pipeline A–G (idempotent)
make container-up PROFILE=dev
make container-up PROFILE=prod
```

Before using these commands, follow [FIRST_INSTALL.md](FIRST_INSTALL.md). It is
the authoritative checklist of directories, non-secret manifests, credential
files, manual apply gates, and activation steps.

`make bootstrap` runs the inner pipeline non-interactively as the host UID/GID inside the pinned image. `make container-run` mounts live credentials at `/run/csoc-credentials` read-only and the workspace at `/workspace`.

The two persistent containers are isolated operator shells with different
kubeconfig mounts. They are convenient for simultaneous administration, but
they do not perform reconciliation: Argo CD runs inside each CSOC and continues
Git synchronization when the local containers are stopped.

## Bootstrap sequence

```
A container-build    B magnum-provision   C magnum-wait
D magnum-kubeconfig  E argocd-install     F capi-secret
G argocd-bootstrap   ← Argo installs CAPI/CAPO from here
```

Steps A–F prepare the management cluster. Step G applies the app-of-apps root Application; every subsequent controller and fleet reconciliation is fully declarative.

## Repository layout

```
argocd/              AppProjects, Applications, App-of-Apps, and Argo CD install values
controllers/         controller Applications (cert-manager, CAPI Operator, KRO, ORC)
iac/magnum/          shared Magnum parameters (no secrets)
iac/csoc/profiles/   dev/prod ownership, immutable sizing, and Git revisions
scripts/host/        host-only image build/run and outer bootstrap entry point
scripts/bootstrap/   in-container pipeline (Magnum, Argo CD, credentials)
scripts/operations/  explicit operator actions: diagnose, inventory, delete
scripts/lib/         source-only .bash libraries
scripts/tools/       local validation and secret scanning
tests/               local lifecycle assertions (no live provisioning)
versions.env         pinned versions for all CLIs and controllers
```

## Credentials

Two separate application credentials are required even when CSOC and spoke share one OpenStack project:

| File | Purpose |
|------|---------|
| `scripts/host/credentials/magnum-clouds.yaml` | Short-lived, unrestricted — Magnum create/delete only |
| `scripts/host/credentials/accounts/<identity>/clouds.yaml` | Restricted — CAPO, ORC, CCM, Cinder CSI |

Neither file is tracked. Copy and fill in the examples, then `chmod 600` both files. See [scripts/host/credentials/README.md](scripts/host/credentials/README.md).

## Argo CD conventions

- All Applications must descend from `argocd/app-of-apps.yaml` — never apply orphan Applications.
- AppProjects must restrict `sourceRepos`, `destinations`, and `clusterResourceWhitelist` explicitly.
- `prune: false` everywhere — cluster and network retirement is always a deliberate operator action.
- Workloads reach spoke clusters through KRO-produced CAPI `ClusterResourceSet` addons; do not add ApplicationSets.

## Bash conventions

- All executable scripts: `set -euo pipefail` + `source scripts/lib/logging.bash`.
- `scripts/lib/*.bash` are source-only and must not be executed directly.
- Idempotent: check state before acting (`os::resource_exists`, `k8s::namespace_exists`).
- All Kubernetes manifests: `kubectl apply --server-side`.

## Validation

```bash
make validate   # static Bash/YAML/JSON, Kustomize, Helm, secret-scan, and lifecycle tests
```

The validation gate is the authoritative local check; GitHub Actions is not used.
For retirement and recovery procedures, see [OPERATIONS.md](OPERATIONS.md).
