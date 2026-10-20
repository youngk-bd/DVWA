#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: ./tools/09-activate-vm.sh

Starts the deployed DVWA VM and waits for Azure to report completion. This does
not recreate compute removed with vm_deployed=false; use 12-restore-compute.sh
for that state.
EOF
  exit 0
fi

ensure_azure_subscription

info "Starting ${VM_NAME}."
az vm start \
  --subscription "${ARM_SUBSCRIPTION_ID}" \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --name "${VM_NAME}" \
  --output none

info "${VM_NAME} is running."
