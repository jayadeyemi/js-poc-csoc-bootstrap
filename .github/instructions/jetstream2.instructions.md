---
applyTo: "**"
---
# Jetstream2 CSOC — bootstrap repo

Full reference: [AGENTS.md](../../AGENTS.md) · Four repos: `js-poc-csoc-bootstrap` / `js-poc-csoc-platform-apis` / `js-poc-csoc-fleet` / `js-poc-csoc-app-catalog` at `github.com/jayadeyemi/`

**Day-2 cluster operations belong in `js-poc-csoc-fleet`**, not in scripts here.

## Conventions

### Bash scripts
- All scripts begin with `set -euo pipefail`.
- Source `scripts/lib/logging.sh` for all log output — never use `echo` directly for status messages.
- Source `scripts/lib/openstack.sh` for OpenStack operations.
- Source `scripts/lib/k8s.sh` for Kubernetes operations.
- Scripts must be idempotent: check current state before creating resources.
- Use the POSIX path `"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` to compute `SCRIPT_DIR`.

### IaC
- Parameters live in `*.env` files under `iac/` — no secrets, only configuration.
- CAPI manifests use `${VARIABLE}` for `envsubst`; do not use Helm-style `{{ }}` syntax.
- Apply all Kubernetes manifests with `kubectl apply --server-side`.

### Credentials
- Credentials are **never** committed to git.
- OpenStack credentials use the **application credential** format (`v3applicationcredential`).
- The container mounts `credentials/clouds.yaml` read-only.
- CAPO reads from the `openstack-cloud-config` secret in `capo-system`.

### New workload clusters (day-2 GitOps)
1. Add `customers/<tenant>/<env>/cluster.yaml` (a `SpokeCluster` CR) to `js-poc-csoc-fleet`.
2. Open a PR — Argo CD applies it, KRO reconciles it → CAPI → Jetstream2 cluster.
3. There is no direct CAPI provisioning script; CAPI/CAPO lifecycle belongs to
   Argo CD and CAPI Operator.

### KRO RGDs
- `SpokeCluster` RGD lives in `js-poc-csoc-platform-apis/rgds/spoke-cluster.rgd.yaml`.
- Never rename or remove existing `spec` fields — that creates a new immutable `GraphRevision`.
- Add new fields as optional with defaults.

### Argo CD
- All Applications must descend from `argocd/app-of-apps.yaml` — never apply orphan Applications.
- AppProjects must restrict `sourceRepos`, `destinations`, and `clusterResourceWhitelist`.
- Cluster labels follow `csoc.js2.org/<key>: <value>`.

### Make targets
Always use `make` targets for standard operations. Run `make help` to see all available targets.
