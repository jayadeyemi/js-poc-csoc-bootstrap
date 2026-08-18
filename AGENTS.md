# js-poc-csoc-bootstrap

Bootstraps the **CSOC management cluster** on Jetstream2 Magnum, then installs Argo CD and hands control to GitOps. After bootstrap completes, this repo is the source of truth for Argo CD's own configuration (projects, applicationsets, controller apps).

## Quick start

```bash
make help                  # all available targets
make container-build       # build management container
make bootstrap             # full pipeline A→G (idempotent)
```

Run scripts inside the management container: `make container-run` mounts `credentials/` read-only and the repo at `/workspace`.

## Bootstrap sequence

```
A container-build   B magnum-provision   C magnum-wait
D magnum-kubeconfig E capi-install       F argocd-install
G argocd-bootstrap  ← GitOps takes over from here
```

Steps A–E run before GitOps exists. Steps F–G hand off control to Argo CD. **Never re-run E after G** — CAPI upgrades are owned by Argo thereafter.

## Repo layout

```
scripts/lib/         shared bash libs — source these, never echo directly
scripts/magnum/      Magnum cluster lifecycle (unchanged after GitOps)
scripts/capi/        bootstrap-only CAPI scripts (post-G, Argo owns CAPI)
scripts/argocd/      install.sh + bootstrap-apps.sh (Steps F+G)
scripts/container/   build.sh / run.sh
container/           Dockerfile + entrypoint (non-root, no baked secrets)
credentials/         .gitignored — see credentials/README.md
iac/magnum/          cluster.env — Magnum parameters (no secrets)
iac/capi/            bootstrap-only CAPI template (moves to RGD long-term)
argocd/              AppProjects, ApplicationSets, App-of-Apps, install values
kro/                 ArgoCD Application that installs KRO
controllers/         ArgoCD Applications for CAPI+CAPO, external-secrets
cluster-registration/ spoke auto-registration controller
```

## Bash conventions

- All scripts: `set -euo pipefail` + source `scripts/lib/logging.sh`
- Idempotent: check state before acting (`os::resource_exists`, `k8s::namespace_exists`)
- `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`
- Lib functions: `log::info/warn/error/die/step`, `os::auth_check`, `k8s::apply`, `k8s::ensure_namespace`
- All K8s manifests: `kubectl apply --server-side`

## Credentials

- OpenStack: `v3applicationcredential` in `credentials/clouds.yaml` (never committed)
- GitHub repo auth: SSH deploy key mounted into container, applied by `scripts/argocd/install.sh`
- CAPO: `openstack-cloud-config` secret in `capo-system` — created by `scripts/capi/create-cloud-secret.sh`
- See [credentials/README.md](credentials/README.md)

## Argo CD conventions

- All Applications must descend from `argocd/app-of-apps.yaml` — never apply orphan Applications
- AppProjects must restrict `sourceRepos`, `destinations`, and `clusterResourceWhitelist` explicitly
- Cluster labels: `csoc.js2.org/<key>: <value>`
- ApplicationSets use the cluster generator with label selectors (not the git generator for cluster targeting)

## Custom agents

| Agent | When to use |
|-------|-------------|
| `@jetstream2-ops` | Full pipeline orchestration, Magnum, CAPI |
| `@csoc-architect` | RGD design, Argo config, fleet/catalog architecture |
| `@magnum-provisioner` | Magnum-only operations |
| `@capi-deployer` | CAPI/CAPO debugging |
| `@container-builder` | Dockerfile, tool version bumps |

## Pitfalls

- `iac/capi/templates/openstack-cluster.yaml` is **bootstrap-only** — in the GitOps world its content lives inside the KRO RGD in `js-poc-csoc-platform-apis`
- `scripts/capi/provision-cluster.sh` is deprecated for day-2 ops — use a PR to `js-poc-csoc-fleet` instead
- Never commit `credentials/clouds.yaml` — the `credentials/.gitignore` blocks the whole directory
- Magnum scripts are intentionally outside GitOps — they run before Argo exists

## Next steps

Execute these in order. Do not start live provisioning until phases 1–3 pass
their validation gates.

### 1. Secure and normalize bootstrap

- Pin every CLI and controller version in one version manifest.
- Standardize credential discovery and the `openstack` cloud key across the
  host, container, OpenStack client, CAPO, and documentation.
- Remove secret-bearing output, including the Argo CD initial administrator
  password, and add a repository secret scan.
- Add preflight checks for authentication, quota, networks, images, load
  balancers, keypairs, duplicate names, and existing cluster ownership.

Gate: static checks pass and preflight fails without creating resources when
any prerequisite is missing.

### 2. Repair Magnum management-cluster lifecycle

- Remove all cluster-template creation, publication, update, and deletion code.
- Select the provider-owned Kubernetes 1.34 template only by UUID
  `284de191-b8ea-4dae-9046-6ab982bd1c3a` and validate it before use.
- Persist bootstrap-created cluster UUIDs in ignored local state; never adopt or
  delete a same-named cluster without an explicit, reviewed operation.
- Make kubeconfig merging atomic, backed up, context-preserving, and mode
  `0600`.

Gate: a dry-run resolves the public 1.34 template and an idempotency test cannot
touch unrelated clusters in the shared project.

### 3. Establish one GitOps ownership path

- Bootstrap Argo CD securely, then let Argo install CAPI and CAPO through the
  CAPI Operator; remove the competing post-bootstrap `clusterctl` ownership
  path.
- Apply AppProjects before Applications and add sync waves and controller CRD
  readiness checks.
- Configure repository authentication if these repositories are private.

Gate: all root applications converge from a fresh management cluster without
manual resource ordering.

### 4. Complete the SpokeCluster API

- Replace cross-namespace secret references with `OpenStackClusterIdentity`
  and namespace restrictions.
- Validate `1 <= minNodes <= maxNodes`, expose useful status from CAPI
  conditions, and wait on real readiness conditions.
- Install Calico, OpenStack CCM, and Cinder CSI through reconciled addon
  resources before declaring a spoke ready.
- Register a spoke with Argo when its endpoint and kubeconfig exist, and update
  registration labels and credentials idempotently.
- Run one namespace-scoped Cluster Autoscaler deployment per spoke and annotate
  its MachineDeployment with the declared minimum and maximum.

Gate: a spoke becomes Ready, provisions a Cinder-backed PVC, receives baseline
applications, and scales up and down without crossing its configured bounds.

### 5. End-to-end acceptance

- Validate Bash, YAML, Kustomize, Helm, KRO/CAPI schemas, secret hygiene, and
  container builds in CI.
- Exercise first bootstrap, interrupted bootstrap, repeat bootstrap, spoke
  creation, autoscaling, registration refresh, and deliberately gated cleanup.
- Record operational recovery and credential-rotation procedures before the
  POC is treated as reusable.

Current live blockers observed on 2026-08-18: the project has no visible SSH
keypair, and it contains unrelated Magnum clusters. Preflight must stop on the
missing keypair and must not adopt or mutate those clusters.
