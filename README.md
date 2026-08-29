# js-poc-csoc-bootstrap

Bootstraps profile-separated CSOC management clusters on Jetstream2 Magnum,
installs Argo CD, and hands controllers, RGD definitions, and selected fleet
instances to GitOps.

## CSOC environments

| Profile | Magnum ownership | Git sources | Fleet |
|---|---|---|---|
| `dev` | New `js2-csoc-dev`; 1 × `m3.small` control plane, 1 worker, 20-GiB roots | coordinated `environment/dev` | disabled; graphs only |
| `staging` | New `js2-csoc-staging`; 3 × `m3.small` control plane, 2 workers, 20-GiB roots | coordinated `environment/staging` | assigned dev tuples |
| `prod` | New `js2-csoc-prod`; 3 × `m3.small` control plane, 3 workers, 20-GiB roots | coordinated `environment/prod` | prod and explicitly routed dev tuples |

All three profiles are declarations only: nothing creates them unless an
operator explicitly authorizes and runs provisioning. The existing
`js2-mgmt-cluster-2` remains a legacy staging migration source; it is not
adopted, renamed, or shrunk in place.

## Quick start

```bash
make help              # list all targets
make container-build   # build the pinned management image
make bootstrap         # full pipeline A–G (idempotent)
make container-up PROFILE=dev
make container-up PROFILE=staging
make container-up PROFILE=prod
make containers-status # show operator containers for every profile
make csoc-plan PROFILE=dev
make clusters-verify PROFILE=dev
```

Before using these commands, follow [FIRST_INSTALL.md](FIRST_INSTALL.md). It is
the authoritative checklist of directories, non-secret manifests, credential
files, revision-bound manual apply gates, and activation steps. A gate created
for an older Git commit cannot authorize newly pulled manifests.

`make bootstrap` runs the inner pipeline non-interactively as the host UID/GID inside the pinned image. `make container-run` mounts live credentials at `/run/csoc-credentials` read-only and the workspace at `/workspace`.

The three persistent containers are isolated operator shells with different
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
iac/csoc/profiles/   dev/staging/prod ownership, sizing, and Git revisions
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

- All Applications must descend from the selected profile App-of-Apps — never apply orphan Applications.
- AppProjects must restrict `sourceRepos`, `destinations`, and `clusterResourceWhitelist` explicitly.
- `prune: false` everywhere — cluster and network retirement is always a deliberate operator action.
- V2 RGDs create central Argo Applications that target registered spokes.
  `ClusterResourceSet` and `HelmChartProxy` are compatibility-only delivery
  paths and must not be introduced into v2.

A v2 registration brokers three independently certified Argo identities for
the same spoke endpoint: application (RoleBound only to approved application
namespaces), platform (the explicit foundation inventory), and monitoring (the
explicit monitoring/CRD/webhook inventory). Cluster Autoscaler receives a
fourth certificate in a kubeconfig limited to the owning CAPI namespace. Set a
new `SpokeRegistration.spec.rotationRequest` token for a reviewed rotation;
the broker records distinct hashes and never puts the CAPI admin kubeconfig in
an Argo Secret.

## Bash conventions

- All executable scripts: `set -euo pipefail` + `source scripts/lib/logging.bash`.
- `scripts/lib/*.bash` are source-only and must not be executed directly.
- Idempotent: check state before acting (`os::resource_exists`, `k8s::namespace_exists`).
- All Kubernetes manifests: `kubectl apply --server-side`.

## Validation

```bash
make validate   # static Bash/YAML/JSON, Kustomize, Helm, secret-scan, and lifecycle tests
make cmp-build cmp-verify # functional mode-specific CMP rendering and rejection tests
CSOC_KIND_COMPILE_APPROVED=true make v2-kind-compile # retained local KRO 0.9.3 compile cluster
make validate-clusters # every management profile and every declared spoke
make clusters-verify-all # every provisioned CSOC and all of its active spokes
```

The validation gate recursively enforces one RGD per file, explicit KRO
aggregation permissions without wildcards, account capacity fixtures, chart
schema/GVK/AppProject comparisons, registration create/rotation/cleanup tests,
and absence of `MachineDeployment.spec.replicas`. The kind gate requires every
v2 GraphRevision to be Active/Ready, exercises the pinned CAPI conversion
webhooks, and proves a forced KRO reconcile does not reclaim `replicas` from
Cluster Autoscaler. It leaves its local test cluster available for inspection.
See [iac/csoc/WORKFLOW.md](iac/csoc/WORKFLOW.md) for the supported rename,
resize, immutable-spec replacement, all-container, and all-cluster workflows.
For retirement and recovery procedures, see [OPERATIONS.md](OPERATIONS.md).
