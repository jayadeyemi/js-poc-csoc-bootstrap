#!/usr/bin/env bash
# Run each provisioned profile's live cluster gate in the pinned container.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.bash"
source "${REPO_ROOT}/scripts/lib/csoc-profile.bash"

mapfile -t profiles < <(
  find "${REPO_ROOT}/iac/csoc/profiles" -maxdepth 1 -type f -name '*.profile' \
    -printf '%f\n' | sed 's/\.profile$//' | sort
)

verified=0
for profile in "${profiles[@]}"; do
  state_file=$(
    unset MAGNUM_CLUSTER_NAME MAGNUM_STATE_FILE MAGNUM_KUBECONFIG_DIR
    CSOC_PROFILE="${profile}"
    csoc::load_profile "${REPO_ROOT}"
    printf '%s\n' "${MAGNUM_STATE_FILE}"
  )
  if [[ ! -f "${state_file}" ]]; then
    log::info "Skipping dormant profile ${profile}: no ownership state"
    continue
  fi
  log::step "${profile}" "Validate the CSOC and every active spoke"
  CSOC_PROFILE="${profile}" bash "${REPO_ROOT}/scripts/host/container/run.sh" \
    bash scripts/operations/csoc/verify-all.sh
  ((verified += 1))
done

(( verified > 0 )) || log::die "No provisioned CSOC profile was found"
log::success "Validated ${verified} provisioned CSOC profile(s)"
