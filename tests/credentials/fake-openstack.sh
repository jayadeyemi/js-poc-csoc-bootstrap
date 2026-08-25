#!/usr/bin/env bash
set -euo pipefail

identity=$(basename "$(dirname "${OS_CLIENT_CONFIG_FILE:?OS_CLIENT_CONFIG_FILE is required}")")
case "${identity}" in
  account-a) expected_project=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  account-b) expected_project=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
  *) printf 'Unknown fake identity: %s\n' "${identity}" >&2; exit 64 ;;
esac
project=${FAKE_CREDENTIAL_PROJECT:-${expected_project}}

case "$*" in
  "configuration show -f json")
    printf '{"auth_type":"v3applicationcredential","auth.application_credential_id":"%s-id"}\n' "${identity}"
    ;;
  "token issue -f json")
    printf '{"project_id":"%s"}\n' "${project}"
    ;;
  application\ credential\ show*)
    printf '{"project_id":"%s","unrestricted":false,"expires_at":"2099-01-01T00:00:00Z"}\n' "${project}"
    ;;
  *) printf 'Unhandled fake OpenStack command: %s\n' "$*" >&2; exit 64 ;;
esac
