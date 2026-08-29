#!/usr/bin/env bash
# Source-only CSOC environment selection. Profiles separate cluster ownership,
# kubeconfigs, immutable Magnum sizing, and Git revisions.

csoc::load_profile() {
  local repo_root=${1:?repository root is required}
  local profile=${CSOC_PROFILE:-dev}
  local profile_file="${repo_root}/iac/csoc/profiles/${profile}.profile"

  [[ "${profile}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || { printf 'Invalid CSOC_PROFILE: %s\n' "${profile}" >&2; return 64; }
  [[ -f "${profile_file}" ]] \
    || { printf 'Unknown CSOC profile: %s\n' "${profile}" >&2; return 66; }

  # Profile defaults are loaded before shared defaults so explicit environment
  # overrides remain possible for isolated tests and reviewed operations.
  # shellcheck disable=SC1090
  source "${profile_file}"
  # shellcheck source=iac/magnum/cluster.env
  source "${repo_root}/iac/magnum/cluster.env"

  [[ "${CSOC_PROFILE_NAME}" == "${profile}" ]] \
    || { printf 'Profile identity mismatch in %s\n' "${profile_file}" >&2; return 65; }
  [[ "${CSOC_FLEET_ENABLED}" == true || "${CSOC_FLEET_ENABLED}" == false ]] \
    || { printf 'CSOC_FLEET_ENABLED must be true or false\n' >&2; return 65; }
  [[ "${CSOC_FLEET_PATH}" == "accounts/${profile}" ]] \
    || { printf 'CSOC_FLEET_PATH must match the selected profile\n' >&2; return 65; }
  [[ "${MAGNUM_CLUSTER_NAME}" == "js-csoc-${profile}" ]] \
    || { printf 'MAGNUM_CLUSTER_NAME must be js-csoc-%s\n' "${profile}" >&2; return 65; }

  CSOC_PROFILE=${profile}
  MAGNUM_STATE_FILE=${MAGNUM_STATE_FILE:-"${repo_root}/${MAGNUM_STATE_FILE_REL}"}
  MAGNUM_KUBECONFIG_DIR=${MAGNUM_KUBECONFIG_DIR:-"${repo_root}/${MAGNUM_KUBECONFIG_DIR_REL}"}
  CSOC_ARGO_ROOT_MANIFEST=${CSOC_ARGO_ROOT_MANIFEST:-"${repo_root}/${CSOC_ARGO_ROOT_MANIFEST_REL}"}

  export CSOC_PROFILE CSOC_PROFILE_NAME CSOC_FLEET_ENABLED
  export CSOC_BOOTSTRAP_REVISION CSOC_CATALOG_REVISION CSOC_FLEET_REVISION
  export CSOC_APPLICATION_DIR_REL CSOC_FLEET_PATH
  export MAGNUM_STATE_FILE MAGNUM_KUBECONFIG_DIR CSOC_ARGO_ROOT_MANIFEST
  export MAGNUM_CLUSTER_NAME MAGNUM_MASTER_COUNT MAGNUM_MASTER_FLAVOR
  export MAGNUM_NODE_COUNT MAGNUM_WORKER_FLAVOR MAGNUM_MIN_NODE_COUNT
  export MAGNUM_MAX_NODE_COUNT MAGNUM_EXPECTED_INITIAL_NODES
  export MAGNUM_BOOT_VOLUME_SIZE MAGNUM_AUTO_SCALING_ENABLED
}
