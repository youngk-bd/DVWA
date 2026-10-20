#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

local_port="${DVWA_BASTION_LOCAL_PORT:-8080}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-port)
      [[ $# -ge 2 ]] || die "--local-port requires a port number."
      local_port="$2"
      shift 2
      ;;
    --help)
      cat <<'EOF'
Usage: ./tools/13-open-bastion-tunnel.sh [--local-port PORT]

Runs the Azure CLI Bastion tunnel from localhost to the private DVWA web port.
The Bastion resources and HTTP allowlist must already exist. Leave this command
running and press Ctrl-C to close the tunnel.

Environment:
  DVWA_BASTION_LOCAL_PORT  Local listener port (default: 8080).
EOF
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${local_port}" =~ ^[0-9]+$ ]] || die "Local port must be an integer."
((local_port >= 1024 && local_port <= 65535)) || die "Local port must be from 1024 through 65535."

ensure_azure_subscription

az extension show --name bastion >/dev/null 2>&1 ||
  die "Azure CLI Bastion extension is missing. Run: az extension add --name bastion --upgrade"

vm_id="$(az vm show \
  --subscription "${ARM_SUBSCRIPTION_ID}" \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --name "${VM_NAME}" \
  --query id \
  --output tsv)"

[[ -n "${vm_id}" ]] || die "Could not resolve the ${VM_NAME} resource ID."

info "Opening http://127.0.0.1:${local_port} through Azure Bastion. Press Ctrl-C to close."
exec az network bastion tunnel \
  --subscription "${ARM_SUBSCRIPTION_ID}" \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --name bastion-dvwa \
  --target-resource-id "${vm_id}" \
  --resource-port 80 \
  --port "${local_port}"
