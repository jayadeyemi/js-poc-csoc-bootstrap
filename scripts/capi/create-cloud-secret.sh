#!/usr/bin/env bash
# Idempotently create the CAPO secret "openstack-cloud-config" from clouds.yaml.
# This secret authorises the OpenStack provider to manage infrastructure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"
source "${REPO_ROOT}/scripts/lib/k8s.sh"

# Resolve clouds.yaml — prefer host path, fall back to container path.
CLOUDS_YAML="${CLOUDS_YAML:-${HOME}/.config/openstack/clouds.yaml}"
[[ -f "${CLOUDS_YAML}" ]] \
  || log::die "clouds.yaml not found at ${CLOUDS_YAML}. Set CLOUDS_YAML env var."

SECRET_NAMESPACE="${CAPO_SECRET_NAMESPACE:-capo-system}"

log::step 1 "Ensuring namespace '${SECRET_NAMESPACE}'"
k8s::ensure_namespace "${SECRET_NAMESPACE}"

log::step 2 "Creating/updating secret 'openstack-cloud-config' in ${SECRET_NAMESPACE}"
k8s::ensure_secret_from_file \
  openstack-cloud-config \
  "${SECRET_NAMESPACE}" \
  clouds.yaml \
  "${CLOUDS_YAML}"

log::success "Secret 'openstack-cloud-config' is up-to-date in namespace '${SECRET_NAMESPACE}'."
