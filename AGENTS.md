# js-poc-csoc-bootstrap

## Environment invariants

- Profiles are exactly `dev`, `staging`, and `prod`; their cluster names are
  exactly `js-csoc-dev`, `js-csoc-staging`, and `js-csoc-prod`.
- Each profile tracks `environment/<profile>` in all three repositories and
  owns unique state, kubeconfig, credential, and container paths.
- Dev installs controllers/RGDs only. Staging owns assigned dev tuples. Prod
  owns prod tuples plus explicitly routed dev tuples.
- Never rename, adopt, or shrink an existing Magnum cluster. Plan a blue/green
  migration with backup, acceptance, rollback, and exact-UUID retirement.
- Boot volumes are OS/controller storage, not application persistence. Use 20
  GiB for all three profiles unless current image-size preflight evidence
  requires more; use separate Cinder PVCs for persistent application data.
- No script may infer ownership from a cluster name. Only the profile's ignored
  state file can authorize mutable operations, and deletion remains explicit.
- Static validation may run freely. Provisioning, apply, mutation, deletion,
  autoscaling installation, and credential creation require live authorization.
- The v2 catalog uses one RGD per YAML file in nested ownership directories;
  static validation must discover that inventory recursively.
- Register a v2 spoke as soon as its control-plane API is reachable; never wait
  on `ClusterFoundation`, because central Argo must deliver that foundation.
- Keep separate namespace-limited application, explicit platform, and explicit
  monitoring Argo identities. The spoke-local Cluster Autoscaler receives only a renewable,
  namespace-scoped management kubeconfig; never copy the CAPI admin kubeconfig.
- Account namespace creation and labels are bootstrap prerequisites. A
  `SpokeAccount` references that namespace and must never own it.
- Validate every supported chart through the functional CMP image and compile
  all RGDs to Active GraphRevisions before a candidate commit is promoted.

Bootstraps the **CSOC management cluster** on Jetstream2 Magnum, then installs Argo CD and hands controllers, RGD definitions, and fleet instances to GitOps.

The existing `js2-mgmt-cluster-2` is `PROFILE=dev` and tracks catalog/fleet
`main`. `PROFILE=prod` is dormant, uses an immutable three-member `m3.quad`
control plane, tracks coordinated `release/prod` branches, and has no fleet
Application. Always state the profile in live operations.

## Quick start

```bash
make help                  # all available targets
make container-build       # build management container
make bootstrap PROFILE=dev # full pipeline A→G (idempotent)
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
iac/magnum/          shared Magnum parameters (no secrets)
iac/csoc/profiles/   environment ownership, sizing, and Git revisions
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

- CSOC/Magnum: unrestricted; an intentionally non-expiring credential is supported
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
- The CSOC-local `HelloApp` is a direct KRO graph. `SpokeHelloApp` is centrally
  delivered through CAPI, while `SpokeGitOps` installs spoke-local Argo CD and
  a repository root. Never give one workload both owners or reuse a
  CAPO/Magnum Kubernetes API load balancer for an application.

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
