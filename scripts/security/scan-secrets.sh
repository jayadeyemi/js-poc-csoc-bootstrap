#!/usr/bin/env bash
# Fail when publishable repository content resembles a live credential.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/logging.sh"

cd "${REPO_ROOT}"

PATTERN='(-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|client-key-data:[[:space:]]*[A-Za-z0-9+/=]{20,}|application_credential_secret:[[:space:]]*[A-Za-z0-9][A-Za-z0-9._~+/-]{15,})'

if rg --hidden --line-number --pcre2 "${PATTERN}" \
  -g '!.git/**' \
  -g '!credentials/clouds.yaml' \
  -g '!credentials/magnum-clouds.yaml' \
  -g '!credentials/runtime-clouds.yaml' \
  -g '!credentials/*.pem' \
  -g '!scripts/security/scan-secrets.sh' .; then
  log::die "Potential credential material found in publishable files"
fi

for credential_file in credentials/magnum-clouds.yaml credentials/runtime-clouds.yaml; do
  git check-ignore -q "${credential_file}" \
    || log::die "${credential_file} is not ignored"
done

log::success "Repository secret scan passed"
