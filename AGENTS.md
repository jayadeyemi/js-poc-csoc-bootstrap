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
D magnum-kubeconfig E argocd-install     F capi-secret
G argocd-bootstrap  ← Argo installs CAPI/CAPO from here
```

Steps A–F prepare the management cluster. Step G hands control to Argo CD;
CAPI/CAPO installation and upgrades always remain declarative.

## Repo layout

```
scripts/lib/         shared bash libs — source these, never echo directly
scripts/magnum/      Magnum cluster lifecycle (unchanged after GitOps)
scripts/capi/        CAPO/workload runtime secret creation only
scripts/argocd/      install.sh + bootstrap-apps.sh (Steps F+G)
scripts/container/   build.sh / run.sh
container/           Dockerfile + entrypoint (non-root, no baked secrets)
credentials/         .gitignored — see credentials/README.md
iac/magnum/          cluster.env — Magnum parameters (no secrets)
argocd/              AppProjects, ApplicationSets, App-of-Apps, install values
controllers/         CAPO identity and SpokeCluster admission policy
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
- CAPO: `openstack-cloud-config` in `capo-system`, plus a workload
  `cloud.conf` resource-set secret in `spokeclusters`
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

- There is no direct CAPI installer or workload provisioning script; use a
  fleet PR and the Argo/KRO reconciliation path.
- Never commit `credentials/clouds.yaml` — the `credentials/.gitignore` blocks the whole directory
- Magnum scripts are intentionally outside GitOps — they run before Argo exists
