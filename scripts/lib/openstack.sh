#!/usr/bin/env bash
# OpenStack helper functions — source this file, do not execute directly.
set -euo pipefail

# Verify OpenStack credentials are functional.
os::auth_check() {
  openstack token issue -f value -c id >/dev/null 2>&1 \
    || log::die "OpenStack auth failed. Check credentials or OS_CLOUD value."
}

# Returns 0 if the named resource exists, 1 otherwise.
# Usage: os::resource_exists <type> <name>
os::resource_exists() {
  local resource_type=$1 resource_name=$2
  openstack "${resource_type}" show "${resource_name}" -f value -c id >/dev/null 2>&1
}

# Returns the Magnum cluster's status string, or "NOT_FOUND".
os::cluster_status() {
  local cluster_name=$1
  openstack coe cluster show "${cluster_name}" -f value -c status 2>/dev/null \
    || echo "NOT_FOUND"
}

# Returns the Magnum cluster template's UUID, or empty string.
os::cluster_template_id() {
  local template_name=$1
  openstack coe cluster template show "${template_name}" -f value -c uuid 2>/dev/null \
    || true
}

# Idempotently create a Magnum cluster template; prints the UUID on success.
os::ensure_cluster_template() {
  local name=$1; shift
  local existing
  existing=$(os::cluster_template_id "${name}")
  if [[ -n "${existing}" ]]; then
    log::info "Cluster template '${name}' already exists (${existing})"
    echo "${existing}"
    return 0
  fi
  log::info "Creating cluster template '${name}'"
  openstack coe cluster template create "${name}" "$@" -f value -c uuid
}
