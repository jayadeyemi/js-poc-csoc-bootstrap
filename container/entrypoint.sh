#!/usr/bin/env bash
# Container entrypoint: validates credentials are present, then executes the given command.
set -euo pipefail

CLOUDS_YAML="${HOME}/.config/openstack/clouds.yaml"

if [[ ! -f "${CLOUDS_YAML}" ]]; then
  cat >&2 <<'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
WARNING: clouds.yaml not found at expected path:
  /home/jetstream/.config/openstack/clouds.yaml

Mount your credentials directory when running the container.
See credentials/README.md for instructions.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
fi

exec "$@"
