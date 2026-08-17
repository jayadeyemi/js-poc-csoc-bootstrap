---
applyTo: "**"
---
# Jetstream2 CSOC Project

This workspace provisions Kubernetes infrastructure on the Indiana University **Jetstream2** OpenStack cloud using:

- **OpenStack Magnum** — management Kubernetes cluster
- **Cluster API + CAPO** — workload cluster lifecycle management

## Core conventions

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

### New workload clusters
1. Copy `iac/capi/clusters/example-cluster/` to a new directory.
2. Edit `values.env` with cluster-specific parameters.
3. Run `make capi-cluster CLUSTER_DIR=iac/capi/clusters/<new-name>`.

### Make targets
Always use `make` targets for standard operations. Run `make help` to see all available targets.
