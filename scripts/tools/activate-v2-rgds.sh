#!/usr/bin/env bash
# Apply the unpublished v2 RGD package and require every compiled revision to be Ready.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CATALOG_ROOT="${APP_CATALOG_ROOT:-${REPO_ROOT}/../js-poc-csoc-app-catalog}"

[[ "${CSOC_V2_ACTIVATION_APPROVED:-false}" == true ]] || {
  echo "set CSOC_V2_ACTIVATION_APPROVED=true for an explicitly selected non-production CSOC" >&2
  exit 1
}
[[ -n "${KUBECONFIG:-}" && -f "${KUBECONFIG}" ]] || { echo "KUBECONFIG is required" >&2; exit 1; }
expected_context=${CSOC_EXPECTED_CONTEXT:?CSOC_EXPECTED_CONTEXT is required}
actual_context=$(kubectl config current-context)
[[ "${actual_context}" == "${expected_context}" ]] || {
  echo "refusing v2 activation on context ${actual_context}; expected ${expected_context}" >&2
  exit 1
}

rendered=$(mktemp)
trap 'rm -f -- "${rendered}"' EXIT HUP INT TERM
kubectl kustomize "${CATALOG_ROOT}/rgds/v2-hubs" >"${rendered}"
mapfile -t rgds < <(yq eval-all -o=json '[select(.kind == "ResourceGraphDefinition") | .metadata.name]' "${rendered}" | jq -r '.[]' | sort)
[[ ${#rgds[@]} -eq 23 ]] || { echo "expected 23 v2 RGDs, found ${#rgds[@]}" >&2; exit 1; }

deadline=$((SECONDS + ${CSOC_V2_COMPILE_TIMEOUT_SECONDS:-900}))
wait_active() {
  local rgd=$1
  while true; do
    state=$(kubectl get resourcegraphdefinition "${rgd}" -o jsonpath='{.status.state}' 2>/dev/null || true)
    revision_ready=$(kubectl get graphrevisions.internal.kro.run -o json 2>/dev/null \
      | jq -r --arg rgd "${rgd}" '[.items[] | select(.spec.snapshot.name == $rgd) | .status.conditions[]? | select(.type == "Ready" and .status == "True")] | length' || true)
    if [[ "${state}" == Active && "${revision_ready:-0}" -ge 1 ]]; then break; fi
    if (( SECONDS >= deadline )); then
      kubectl get resourcegraphdefinition "${rgd}" -o yaml >&2 || true
      kubectl get graphrevisions.internal.kro.run -o wide >&2 || true
      echo "timed out waiting for Active GraphRevision: ${rgd}" >&2
      exit 1
    fi
    sleep 5
  done
}

apply_stage() {
  local manifest rgd
  for manifest in "$@"; do
    kubectl apply --server-side --field-manager=csoc-v2-rgd-publisher -f "${CATALOG_ROOT}/rgds/v2-hubs/${manifest}" >/dev/null
  done
  for manifest in "$@"; do
    rgd=$(yq -r '.metadata.name' "${CATALOG_ROOT}/rgds/v2-hubs/${manifest}")
    wait_active "${rgd}"
  done
}

# KRO validates externalRef schemas while compiling. Publish generated API
# identities in dependency order so a clean cluster never relies on retries.
apply_stage infrastructure/spokeaccount.rgds.yaml
apply_stage infrastructure/machineprofile.rgds.yaml infrastructure/spokenetwork.rgds.yaml
apply_stage infrastructure/workloadcluster.rgds.yaml
apply_stage infrastructure/spokenodepool.rgds.yaml infrastructure/spokeregistration.rgds.yaml
apply_stage infrastructure/clusterfoundation.yaml bindings/applicationboundary.rgds.yaml \
  bindings/cephfsaddon.rgds.yaml bindings/gpuruntimeaddon.rgds.yaml bindings/s3csiaddon.rgds.yaml
apply_stage bindings/endpointbinding.rgds.yaml bindings/hubauthbinding.rgds.yaml \
  bindings/secretbundle.rgds.yaml bindings/cinderstoragebinding.rgds.yaml \
  bindings/cephfsvolumebinding.rgds.yaml bindings/s3volumebinding.rgds.yaml
apply_stage services/smokeapplication.rgds.yaml services/jupyterhubinstance.rgds.yaml \
  services/monitoringinstance.rgds.yaml services/registrycacheinstance.rgds.yaml \
  services/binderbuildinstance.rgds.yaml services/jupyteroutpostinstance.rgds.yaml

if [[ "${CSOC_REQUIRE_EMPTY_V2_FLEET:-false}" == true ]]; then
  for api in infra.csoc.js2.org delivery.csoc.js2.org services.csoc.js2.org; do
    resources=$(
      while IFS= read -r resource; do
        kubectl get "${resource}" --all-namespaces --ignore-not-found -o name 2>/dev/null || true
      done < <(kubectl api-resources --api-group="${api}" --namespaced=true -o name)
    )
    if [[ -n "${resources}" ]]; then count=$(printf '%s\n' "${resources}" | wc -l); else count=0; fi
    [[ "${count}" -eq 0 ]] || { echo "${api} has ${count} instances; development fleet must be empty" >&2; exit 1; }
  done
fi

echo "all ${#rgds[@]} v2 RGDs have an Active Ready GraphRevision"
