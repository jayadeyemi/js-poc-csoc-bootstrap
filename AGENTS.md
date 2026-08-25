# js-poc-csoc-bootstrap

Bootstraps the **CSOC management cluster** on Jetstream2 Magnum, then installs Argo CD and hands controllers, RGD definitions, and fleet instances to GitOps.

## Quick start

```bash
make help                  # all available targets
make container-build       # build management container
make bootstrap             # full pipeline A→G (idempotent)
```

`make bootstrap` builds the pinned image on the host and runs the inner pipeline
non-interactively as the host UID/GID. `make container-run` mounts the two live
credential locations at `/run/csoc-credentials` read-only and mounts
the workspace at `/workspace`.

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
scripts/host/        host-only Docker build/run and outer bootstrap
scripts/bootstrap/   one-shot management-container pipeline
scripts/operations/  explicit operator diagnostics, inventory, and deletion
scripts/lib/         source-only `.bash` libraries; never execute directly
scripts/tools/       local/container validation and secret scanning
scripts/host/docker/ Dockerfile + entrypoint (non-root, no baked secrets)
scripts/host/credentials/ ignored credentials and tracked examples
iac/magnum/          cluster.env — Magnum parameters (no secrets)
argocd/              rgds/fleet AppProjects, Applications, App-of-Apps, install values
controllers/         controller Applications installed before KRO graphs
```

## Bash conventions

- Executable Bash scripts: `set -euo pipefail` + source
  `scripts/lib/logging.bash`
- `scripts/lib/*.bash` files are source-only and are never executed directly
- Idempotent: check state before acting (`os::resource_exists`, `k8s::namespace_exists`)
- `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`
- Lib functions: `log::info/warn/error/die/step`, `os::auth_check`, `k8s::apply`, `k8s::ensure_namespace`
- All K8s manifests: `kubectl apply --server-side`

## Credentials

- CSOC/Magnum: short-lived unrestricted
  `scripts/host/credentials/magnum-clouds.yaml`
- Spoke provisioning/workloads: a different restricted credential at
  `scripts/host/credentials/accounts/<identity>/clouds.yaml`, even when the
  CSOC and spoke identity use the same OpenStack project
- For each active identity, `<identity>-cloud-config` and
  `<identity>-workload-cloud-config` exist only in `spokeclusters-<identity>`
- See [scripts/host/credentials/README.md](scripts/host/credentials/README.md)

## Argo CD conventions

- All Applications must descend from `argocd/app-of-apps.yaml` — never apply orphan Applications
- AppProjects must restrict `sourceRepos`, `destinations`, and `clusterResourceWhitelist` explicitly
- Cluster labels: `csoc.js2.org/<key>: <value>`
- Workloads reach spokes through KRO-produced CAPI addon resources; do not add
  baseline or application ApplicationSets
- The CSOC-local Hello workload is a direct KRO graph. CSOC and spoke Hello
  Services use separate internal application load balancers; never attach a
  public floating IP or reuse a CAPO/Magnum Kubernetes API load balancer.

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
- Never commit either live credential file; only the two examples are tracked
- Magnum scripts are intentionally outside GitOps — they run before Argo exists
