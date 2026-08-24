#!/usr/bin/env bash
# Structured logging utilities — source this file, do not execute directly.
set -euo pipefail

readonly _LOG_RED='\033[0;31m'
readonly _LOG_GREEN='\033[0;32m'
readonly _LOG_YELLOW='\033[1;33m'
readonly _LOG_BLUE='\033[0;34m'
readonly _LOG_NC='\033[0m'

log::info()    { echo -e "${_LOG_BLUE}[INFO]${_LOG_NC}    $(date -u +%H:%M:%SZ)  $*" >&2; }
log::success() { echo -e "${_LOG_GREEN}[OK]${_LOG_NC}      $(date -u +%H:%M:%SZ)  $*" >&2; }
log::warn()    { echo -e "${_LOG_YELLOW}[WARN]${_LOG_NC}    $(date -u +%H:%M:%SZ)  $*" >&2; }
log::error()   { echo -e "${_LOG_RED}[ERROR]${_LOG_NC}   $(date -u +%H:%M:%SZ)  $*" >&2; }
log::die()     { log::error "$*"; exit 1; }

log::step() {
  local step=$1; shift
  echo -e "\n${_LOG_BLUE}━━━ Step ${step}:${_LOG_NC} $*\n" >&2
}
