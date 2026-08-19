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

# Returns UUIDs of Magnum clusters whose name exactly matches the argument.
os::cluster_ids_by_name() {
  local cluster_name=$1
  openstack coe cluster list -f json \
    | jq -r --arg name "${cluster_name}" \
        '.[] | select((.name // .Name) == $name) | (.uuid // .UUID)'
}

# Returns the Magnum cluster's status by UUID, or "NOT_FOUND".
os::cluster_status() {
  local cluster_id=$1
  openstack coe cluster show "${cluster_id}" -f value -c status 2>/dev/null \
    || echo "NOT_FOUND"
}

# Resolve the cluster UUID recorded by this bootstrap.
os::owned_cluster_id() {
  local state_file=$1
  [[ -f "${state_file}" ]] || log::die "Bootstrap ownership state not found: ${state_file}"
  jq -er '.cluster_id | select(type == "string" and length > 0)' "${state_file}" \
    || log::die "Invalid ownership state: ${state_file}"
}

# Verify that a recorded UUID still has the expected cluster name.
os::verify_owned_cluster() {
  local state_file=$1 expected_name=$2 cluster_id actual_name
  cluster_id=$(os::owned_cluster_id "${state_file}")
  actual_name=$(openstack coe cluster show "${cluster_id}" -f value -c name 2>/dev/null) \
    || log::die "Owned cluster ${cluster_id} no longer exists; inspect ${state_file}"
  [[ "${actual_name}" == "${expected_name}" ]] \
    || log::die "Ownership state points to '${actual_name}', expected '${expected_name}'"
  printf '%s\n' "${cluster_id}"
}
