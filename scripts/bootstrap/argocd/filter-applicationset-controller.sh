#!/usr/bin/env bash
# Remove the unused ApplicationSet controller objects from the Argo Helm render.
set -euo pipefail

yq eval \
  'select(.metadata.labels."app.kubernetes.io/component" != "applicationset-controller")' \
  -
