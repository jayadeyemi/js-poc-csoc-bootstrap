#!/usr/bin/env bash
# Container entrypoint: validates credentials are present, then executes the given command.
set -euo pipefail

MAGNUM_FILE="${MAGNUM_CLOUDS_YAML:-}"
RUNTIME_DIR="${RUNTIME_CREDENTIALS_DIR:-}"

if [[ -z "${MAGNUM_FILE}" || ! -f "${MAGNUM_FILE}" \
   || -z "${RUNTIME_DIR}" || ! -d "${RUNTIME_DIR}" ]]; then
  cat >&2 <<'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
WARNING: Magnum and account runtime credentials were not mounted.

Use scripts/host/container/run.sh to mount credentials read-only.
See scripts/host/credentials/README.md for instructions.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
fi

export SHELL="${SHELL:-/bin/bash}"
exec "$@"
