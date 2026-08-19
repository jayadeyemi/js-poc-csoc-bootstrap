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
  -g '!credentials/**' \
  -g '!scripts/security/scan-secrets.sh' .; then
  log::die "Potential credential material found in publishable files"
fi

git check-ignore -q credentials/clouds.yaml \
  || log::die "credentials/clouds.yaml is not ignored"

log::success "Repository secret scan passed"
