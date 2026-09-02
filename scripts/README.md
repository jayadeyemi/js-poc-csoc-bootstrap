# Script execution boundaries

The directory name identifies where a script is intended to run and whether
it is part of the automatic bootstrap path. Prefer the stable `make` targets
in the repository root; their implementation paths may change without
changing the operator interface.

## `host/` — host-only launchers

These scripts run on the workstation. They build and start the pinned
management image, mount the workspace and credential files, and hand control
to the in-container pipeline.

- `host/bootstrap.sh`: host entry point used by `make bootstrap`
- `host/container/build.sh`: builds the pinned management image
- `host/container/run.sh`: starts the management container

## `bootstrap/` — automatic in-container pipeline

These scripts are intended to run inside the pinned management container.
`pipeline.sh` calls the required Magnum, Argo CD, and spoke-credential steps
in order. Scripts under `bootstrap/magnum/` are lifecycle stages, not
independent jobs running in the background.

- `bootstrap/pipeline.sh`: ordered bootstrap coordinator
- `bootstrap/magnum/`: preflight, provision, wait, kubeconfig, node-group, and
  acceptance checks
- `bootstrap/argocd/`: management-cluster Argo CD installation, the narrow
  post-render filter that removes the unused ApplicationSet controller, and
  root-app bootstrap
- `bootstrap/credentials/`: loads only the restricted account credential
  after management-cluster reachability has been confirmed

## `operations/` — explicit operator actions

Nothing here is called as an ordinary bootstrap stage unless another script
explicitly invokes it for diagnostics. These commands are intentionally
separate because they inspect provider state or perform gated cleanup.

- `operations/magnum/diagnose.sh`: read-only diagnostic bundle
- `operations/magnum/inventory-templates.sh`: read-only template inventory
- `operations/magnum/delete-owned.sh`: exact-UUID, ownership-gated deletion or
  deletion monitoring
- `operations/spokes/destroy-spoke.sh`: Git-retirement and project-gated
  workload → CAPI/CAPO → KRO/ORC spoke teardown

## `lib/` — source-only Bash modules

Files ending in `.bash` are sourced by executable scripts. They are not jobs
and should not be invoked directly.

## `tools/` — local development checks

These scripts run static validation, fake-CLI lifecycle tests, manifest
rendering, and secret scanning. `make validate` is the authoritative local
gate. The v2 contract check discovers the catalog's single-document RGD files
recursively below `rgds/v2-hubs/`, compares chart GVKs with AppProject/RBAC policy,
and runs fake registration lifecycle/capacity tests. `make cmp-build
cmp-verify` exercises mode-specific inputs in the real CMP image.
`CSOC_KIND_COMPILE_APPROVED=true make v2-kind-compile` compiles both RGD generations,
exercises the pinned CAPI conversion webhooks, verifies autoscaler ownership of
`MachineDeployment.spec.replicas` across a forced KRO reconcile, and retains
the local kind cluster. `make v1-activate` and `make v2-activate` are the
explicitly gated equivalents for a selected non-production management cluster.
The v1 activator follows each declared sync wave and only recreates an inactive
RGD when separately approved and its generated Kind has zero instances.

Before the first v2 fleet apply, `preflight-v2-spoke.sh` resolves every numeric
flavor, image, volume type, failure domain, external network, project, and live
compute/volume headroom against the rendered account capacity budget. On an
idempotent replay with an existing v2 cluster it checks absolute quotas instead
and labels the result so it is not mistaken for a fresh headroom measurement.

## Test code outside `scripts/`

- `tests/` runs locally or in the management image and never provisions live
  infrastructure.

## Stable operator commands

Run `make help` for the full list. Except for `make bootstrap`, a target runs
the named script directly in the current shell; use the pinned management
container unless the host already has the required toolchain. The most
important boundaries are:

- `make bootstrap`: host launcher, then ordered in-container bootstrap
- `make preflight`, `make magnum-provision`, `make magnum-verify`:
  individual lifecycle stages using the pinned environment
- `make magnum-diagnose`, `make magnum-templates`: read-only operations
- `bash scripts/operations/magnum/delete-owned.sh <uuid>`: reviewed,
  exact-UUID operation
- `bash scripts/operations/spokes/destroy-spoke.sh --identity <id> --spoke
  <name> --confirm <name>`: reviewed spoke teardown
- `make validate`: local checks only
