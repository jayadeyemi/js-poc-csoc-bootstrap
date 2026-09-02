#!/usr/bin/env bash
# Validate every management profile and every declarative spoke, active or not.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
FLEET_ROOT="${WORKSPACE_ROOT}/js-poc-csoc-fleet"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"
source "${REPO_ROOT}/versions.env"
# shellcheck source=iac/magnum/cluster.env
source "${REPO_ROOT}/iac/magnum/cluster.env"

for command_name in find jq sed sort yq; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || log::die "Required cluster-validation command not found: ${command_name}"
done
[[ -d "${FLEET_ROOT}/.git" ]] || log::die "Fleet repository not found: ${FLEET_ROOT}"

mapfile -t profiles < <(
  find "${REPO_ROOT}/iac/csoc/profiles" -maxdepth 1 -type f -name '*.profile' \
    -printf '%f\n' | sed 's/\.profile$//' | sort
)
(( ${#profiles[@]} > 0 )) || log::die "No CSOC profiles are declared"

declare -A cluster_names=()
declare -A state_paths=()
declare -A kubeconfig_paths=()

log::step 1 "Validating every declarative CSOC management profile"
for profile in "${profiles[@]}"; do
  profile_json=$(
    unset CSOC_PROFILE CSOC_PROFILE_NAME CSOC_FLEET_ENABLED CSOC_API_GENERATION
    unset CSOC_BOOTSTRAP_REVISION CSOC_CATALOG_REVISION CSOC_FLEET_REVISION
    unset MAGNUM_CLUSTER_NAME MAGNUM_STATE_FILE MAGNUM_KUBECONFIG_DIR
    unset MAGNUM_MASTER_COUNT MAGNUM_MASTER_FLAVOR MAGNUM_NODE_COUNT
    unset MAGNUM_WORKER_FLAVOR MAGNUM_MIN_NODE_COUNT MAGNUM_MAX_NODE_COUNT
    unset MAGNUM_EXPECTED_INITIAL_NODES MAGNUM_BOOT_VOLUME_SIZE MAGNUM_AUTO_SCALING_ENABLED
    unset CSOC_ARGO_ROOT_MANIFEST CSOC_ARGO_ROOT_MANIFEST_REL
    unset CSOC_APPLICATION_DIR_REL CSOC_FLEET_PATH
    CSOC_PROFILE="${profile}"
    csoc::load_profile "${REPO_ROOT}"
    jq -n \
      --arg profile "${CSOC_PROFILE_NAME}" \
      --arg name "${MAGNUM_CLUSTER_NAME}" \
      --arg state "${MAGNUM_STATE_FILE}" \
      --arg kubeconfigs "${MAGNUM_KUBECONFIG_DIR}" \
      --arg master_count "${MAGNUM_MASTER_COUNT}" \
      --arg node_count "${MAGNUM_NODE_COUNT}" \
      --arg min_nodes "${MAGNUM_MIN_NODE_COUNT}" \
      --arg max_nodes "${MAGNUM_MAX_NODE_COUNT}" \
      --arg expected "${MAGNUM_EXPECTED_INITIAL_NODES}" \
      --arg master_flavor "${MAGNUM_MASTER_FLAVOR}" \
      --arg worker_flavor "${MAGNUM_WORKER_FLAVOR}" \
      --arg boot_volume "${MAGNUM_BOOT_VOLUME_SIZE}" \
      --arg autoscaling "${MAGNUM_AUTO_SCALING_ENABLED}" \
      --arg fleet "${CSOC_FLEET_ENABLED}" \
      --arg api_generation "${CSOC_API_GENERATION}" \
      --arg bootstrap_revision "${CSOC_BOOTSTRAP_REVISION}" \
      --arg catalog_revision "${CSOC_CATALOG_REVISION}" \
      --arg fleet_revision "${CSOC_FLEET_REVISION}" \
      --arg root_manifest "${CSOC_ARGO_ROOT_MANIFEST}" \
      '{profile:$profile,name:$name,state:$state,kubeconfigs:$kubeconfigs,
        masterCount:($master_count|tonumber),nodeCount:($node_count|tonumber),
        minNodes:($min_nodes|tonumber),maxNodes:($max_nodes|tonumber),
        expectedNodes:($expected|tonumber),masterFlavor:$master_flavor,
        workerFlavor:$worker_flavor,bootVolumeGiB:($boot_volume|tonumber),
        autoscalingEnabled:($autoscaling == "true"),fleetEnabled:($fleet == "true"),
        apiGeneration:$api_generation,
        revisions:{bootstrap:$bootstrap_revision,catalog:$catalog_revision,fleet:$fleet_revision},
        rootManifest:$root_manifest}'
  ) || log::die "Unable to load CSOC profile ${profile}"

  jq -e '
    .profile != "" and .name != "" and
    (.masterCount >= 1) and (.nodeCount >= 1) and
    (.minNodes >= 1) and (.minNodes <= .nodeCount) and (.nodeCount <= .maxNodes) and
    (.expectedNodes == (.masterCount + .nodeCount)) and
    (.masterCount == 1 or (.masterCount >= 3 and (.masterCount % 2 == 1))) and
    (.masterFlavor != "") and (.workerFlavor != "") and
    (.bootVolumeGiB >= 20 and .bootVolumeGiB <= 60) and
    ([.revisions[] | length > 0] | all) and
    (.apiGeneration == "v1" or .apiGeneration == "v2")
  ' <<<"${profile_json}" >/dev/null \
    || log::die "Invalid counts, bounds, flavors, or revisions in profile ${profile}"

  name=$(jq -r '.name' <<<"${profile_json}")
  state=$(jq -r '.state' <<<"${profile_json}")
  kubeconfigs=$(jq -r '.kubeconfigs' <<<"${profile_json}")
  root_manifest=$(jq -r '.rootManifest' <<<"${profile_json}")
  [[ -z "${cluster_names[${name}]:-}" ]] \
    || log::die "CSOC cluster name ${name} is reused by ${profile} and ${cluster_names[${name}]}"
  [[ -z "${state_paths[${state}]:-}" ]] \
    || log::die "Ownership state ${state} is reused by multiple profiles"
  [[ -z "${kubeconfig_paths[${kubeconfigs}]:-}" ]] \
    || log::die "Kubeconfig directory ${kubeconfigs} is reused by multiple profiles"
  cluster_names[${name}]="${profile}"
  state_paths[${state}]="${profile}"
  kubeconfig_paths[${kubeconfigs}]="${profile}"

  [[ "${state}" == "${REPO_ROOT}/.state/"* ]] \
    || log::die "Profile ${profile} ownership state must remain under .state"
  [[ "${kubeconfigs}" == "${REPO_ROOT}/.state/"* ]] \
    || log::die "Profile ${profile} kubeconfigs must remain under .state"
  [[ -f "${root_manifest}" ]] \
    || log::die "Profile ${profile} root manifest does not exist: ${root_manifest}"

  if [[ -f "${state}" ]]; then
    if ! jq -e --arg name "${name}" --arg template "${MAGNUM_TEMPLATE_ID}" \
      '.cluster_id != "" and .cluster_name == $name and .template_id == $template' \
      "${state}" >/dev/null; then
      legacy_name="csoc-${profile}"
      jq -e --arg name "${legacy_name}" --arg template "${MAGNUM_TEMPLATE_ID}" \
        '.cluster_id != "" and .cluster_name == $name and .template_id == $template' \
        "${state}" >/dev/null \
        || log::die "Profile ${profile} ownership state does not match its declared or legacy name/template"
      log::warn "${profile}: legacy ownership state ${legacy_name} is retained; live preflight must block ${name} until retirement completes"
    fi
  fi
  log::success "${profile}: ${name} declaration is internally consistent"
done

log::step 2 "Validating every active, example, and retired SpokeCluster declaration"
declare -A spoke_keys=()
spoke_count=0
immutable_count=0
while IFS= read -r -d '' yaml_file; do
  while IFS='|' read -r kind name namespace min_nodes max_nodes image_id version; do
    [[ -n "${kind}" ]] || continue
    case "${kind}" in
      SpokeCluster)
        [[ -n "${name}" && -n "${namespace}" ]] \
          || log::die "SpokeCluster lacks name or namespace: ${yaml_file}"
        [[ "${min_nodes}" =~ ^[0-9]+$ && "${max_nodes}" =~ ^[0-9]+$ ]] \
          || log::die "SpokeCluster ${namespace}/${name} has non-integer bounds"
        (( min_nodes >= 1 && min_nodes <= max_nodes )) \
          || log::die "SpokeCluster ${namespace}/${name} violates 1 <= minNodes <= maxNodes"
        key="${namespace}/${name}"
        if [[ -n "${spoke_keys[${key}]:-}" && "${yaml_file}" == "${FLEET_ROOT}/environments/"* ]]; then
          log::die "Active SpokeCluster ${key} is declared more than once"
        fi
        spoke_keys[${key}]="${yaml_file}"
        ((spoke_count += 1))
        ;;
      ImmutableSpokeConfig)
        [[ "${image_id}" == "${WORKLOAD_IMAGE_ID}" ]] \
          || log::die "${name} uses unapproved image ${image_id}: ${yaml_file}"
        [[ "${version}" == "v${WORKLOAD_KUBERNETES_VERSION}" ]] \
          || log::die "${name} uses unapproved Kubernetes ${version}: ${yaml_file}"
        ((immutable_count += 1))
        ;;
    esac
  done < <(
    yq -r '
      select(.kind == "SpokeCluster" or .kind == "ImmutableSpokeConfig") |
      [.kind, .metadata.name, (.metadata.namespace // ""),
       (.spec.kubernetes.minNodes // ""), (.spec.kubernetes.maxNodes // ""),
       (.spec.compute.imageID // ""), (.spec.kubernetes.version // "")] | join("|")
    ' "${yaml_file}"
  )
done < <(
  find "${FLEET_ROOT}/environments" "${FLEET_ROOT}/examples" -type f \
    \( -name '*.yaml' -o -name '*.yml' \) -print0
)

(( spoke_count > 0 )) || log::die "No SpokeCluster declarations were found"
(( immutable_count > 0 )) || log::die "No ImmutableSpokeConfig declarations were found"
log::success "Validated ${#profiles[@]} CSOC profiles, ${spoke_count} spoke declarations, and ${immutable_count} immutable spoke configurations"
