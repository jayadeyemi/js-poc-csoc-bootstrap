#!/usr/bin/env bash
# Manage persistent operator containers for every declared CSOC profile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"

ACTION=${1:-status}
case "${ACTION}" in
  up|status|stop) ;;
  *) log::die "Usage: $0 {up|status|stop}" ;;
esac

mapfile -t profiles < <(
  find "${REPO_ROOT}/iac/csoc/profiles" -maxdepth 1 -type f -name '*.profile' \
    -printf '%f\n' | sed 's/\.profile$//' | sort
)
(( ${#profiles[@]} > 0 )) || log::die "No CSOC profiles are declared"

for profile in "${profiles[@]}"; do
  log::step "${profile}" "Container ${ACTION}"
  CSOC_PROFILE="${profile}" bash "${SCRIPT_DIR}/manage.sh" "${ACTION}"
done
