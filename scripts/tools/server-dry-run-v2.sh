#!/usr/bin/env bash
# Non-persisting schema/compilation check against a prepared controller cluster.
# This is intentionally separate from `make validate`: it contacts a live API.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CATALOG_ROOT="${REPO_ROOT}/../js-poc-csoc-app-catalog"
source "${REPO_ROOT}/versions.env"

[[ "${CSOC_V2_SERVER_DRY_RUN_APPROVED:-false}" == true ]] || {
  echo "set CSOC_V2_SERVER_DRY_RUN_APPROVED=true after selecting the intended non-production kubeconfig" >&2
  exit 1
}
[[ -n "${KUBECONFIG:-}" && -f "${KUBECONFIG}" ]] || { echo "KUBECONFIG is required" >&2; exit 1; }

for crd in \
  resourcegraphdefinitions.kro.run \
  graphrevisions.internal.kro.run \
  clusters.cluster.x-k8s.io \
  openstackclusters.infrastructure.cluster.x-k8s.io \
  applications.argoproj.io \
  networks.openstack.k-orc.cloud; do
  kubectl get crd "$crd" >/dev/null || { echo "missing pinned-controller CRD: $crd" >&2; exit 1; }
done

rendered=$(mktemp)
trap 'rm -f -- "$rendered"' EXIT
kubectl kustomize "${CATALOG_ROOT}/rgds" >"$rendered"
kubectl apply --server-side --force-conflicts --dry-run=server --field-manager=csoc-v2-schema-test -f "$rendered" >/dev/null

expected=23
actual=$(yq eval-all 'select(.kind == "ResourceGraphDefinition" and (.spec.schema.group == "infra.csoc.js2.org" or .spec.schema.group == "delivery.csoc.js2.org" or .spec.schema.group == "services.csoc.js2.org")) | .metadata.name' "$rendered" | rg -v '^---$' | wc -l)
[[ "$actual" == "$expected" ]] || { echo "expected ${expected} v2 RGDs, found ${actual}" >&2; exit 1; }

echo "KRO ${KRO_VERSION} server-side dry-run accepted the catalog against CAPI ${CAPI_VERSION}, CAPO ${CAPO_VERSION}, and ORC ${ORC_VERSION} CRDs"
