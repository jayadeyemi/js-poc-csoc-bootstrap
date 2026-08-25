---
applyTo: "**"
---
# Jetstream2 CSOC bootstrap conventions

The active architecture has three repositories:

- `js-poc-csoc-bootstrap`: Magnum, Argo, controllers, projects, and root apps.
- `js-poc-csoc-app-catalog`: reusable KRO RGD definitions only.
- `js-poc-csoc-fleet`: CSOC and account/spoke graph instances.

The platform-APIs repository, ApplicationSets, cluster registration, baseline,
security, and observability packages are retired and must not be restored.

## Bash and IaC

- Executable scripts use `set -euo pipefail` and source
  `scripts/lib/logging.bash`.
- Use `scripts/lib/openstack.bash` and `scripts/lib/k8s.bash` where applicable.
- Compute `SCRIPT_DIR` from `${BASH_SOURCE[0]}`.
- Keep operations idempotent and apply Kubernetes manifests server-side.
- Run the complete `make validate` gate for coordinated changes.

## Credentials

- Never commit, print, or embed credential values or secret references.
- Magnum uses the separate unrestricted
  `scripts/host/credentials/magnum-clouds.yaml` credential.
- Each spoke identity uses a restricted
  `scripts/host/credentials/accounts/<identity>/clouds.yaml` credential.
- The loader creates identity-specific CAPO/ORC and workload secrets only in
  `spokeclusters-<identity>`.

## Fleet and KRO

- Add CSOC-local instances under `js-poc-csoc-fleet/csoc/`.
- Add account and spoke instances under
  `js-poc-csoc-fleet/accounts/<identity>/`.
- RGD definitions live only under `js-poc-csoc-app-catalog/rgds/`.
- `SpokeIdentity` is the credential and account boundary.
- Immutable provider restrictions flow through graph-produced ConfigMaps.
- `SpokeCluster` exposes only mutable worker bounds.
- Spoke applications use CAPI addon graphs; CSOC applications use direct KRO
  graphs. Do not create Argo ApplicationSets or registration labels.
- Application load balancers remain internal-only and separate from Kubernetes
  API load balancers.

## Argo

- All Applications descend from `argocd/app-of-apps.yaml`.
- Exactly two custom projects exist: `rgds` and `csoc-fleet`.
- AppProjects explicitly restrict repositories, destinations, and resource
  kinds.
- Manually dry-run, apply, and wait for new projects, RGDs, CRDs, and trusted
  instances before enabling Argo ownership.
