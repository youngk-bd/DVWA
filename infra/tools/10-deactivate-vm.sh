#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assume_yes=false

case "${1:-}" in
  --yes) assume_yes=true ;;
  --help)
    cat <<'EOF'
Usage: ./tools/10-deactivate-vm.sh [--yes]

Deallocates the VM to stop compute billing while retaining the VM, addresses,
OS disk, data disk, and configuration. Without --yes, confirmation is required.
EOF
    exit 0
    ;;
  "") ;;
  *) die "Unknown argument: ${1}" ;;
esac

ensure_azure_subscription

if [[ "${assume_yes}" != true ]]; then
  confirm_action "DEALLOCATE DVWA" "This will deallocate ${VM_NAME}; the application will be unavailable until restarted."
fi

az vm deallocate \
  --subscription "${ARM_SUBSCRIPTION_ID}" \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --name "${VM_NAME}" \
  --output none

info "${VM_NAME} is deallocated. Managed disks and other retained resources may still incur charges."
