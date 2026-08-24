#!/usr/bin/env bash
# Container entrypoint: validates credentials are present, then executes the given command.
set -euo pipefail

MAGNUM_FILE="${MAGNUM_CLOUDS_YAML:-}"
RUNTIME_FILE="${RUNTIME_CLOUDS_YAML:-}"

if [[ -z "${MAGNUM_FILE}" || ! -f "${MAGNUM_FILE}" \
   || -z "${RUNTIME_FILE}" || ! -f "${RUNTIME_FILE}" ]]; then
  cat >&2 <<'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
WARNING: separated Magnum and runtime clouds.yaml files were not mounted.

Use scripts/host/container/run.sh to mount both credential files read-only.
See credentials/README.md for instructions.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
fi

export SHELL="${SHELL:-/bin/bash}"
exec "$@"
