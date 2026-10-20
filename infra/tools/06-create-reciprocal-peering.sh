#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assume_yes=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      assume_yes=true
      shift
      ;;
    --help)
      cat <<'EOF'
Usage: ./tools/06-create-reciprocal-peering.sh [--yes]

Creates the consumer-owned half of a VNet peering after Terraform creates the
DVWA-owned half. The operation is idempotent when the named peering already
exists.

Required environment:
  DVWA_CONSUMER_RESOURCE_GROUP   Consumer VNet resource group.
  DVWA_CONSUMER_VNET_NAME       Consumer VNet name.

Optional environment:
  DVWA_CONSUMER_SUBSCRIPTION_ID Consumer subscription; defaults to ARM_SUBSCRIPTION_ID.
  DVWA_CONSUMER_PEERING_NAME    Peering name; defaults to peer-dvwa.
EOF
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

ensure_azure_subscription
require_environment_variable DVWA_CONSUMER_RESOURCE_GROUP
require_environment_variable DVWA_CONSUMER_VNET_NAME

consumer_subscription_id="${DVWA_CONSUMER_SUBSCRIPTION_ID:-${ARM_SUBSCRIPTION_ID}}"
consumer_peering_name="${DVWA_CONSUMER_PEERING_NAME:-peer-dvwa}"

dvwa_vnet_id="$(
  az network vnet show \
    --subscription "${ARM_SUBSCRIPTION_ID}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --name "${VNET_NAME}" \
    --query id \
    --output tsv
)"

consumer_vnet_id="$(
  az network vnet show \
    --subscription "${consumer_subscription_id}" \
    --resource-group "${DVWA_CONSUMER_RESOURCE_GROUP}" \
    --name "${DVWA_CONSUMER_VNET_NAME}" \
    --query id \
    --output tsv
)"

local_peering_count="$(
  az network vnet peering list \
    --subscription "${ARM_SUBSCRIPTION_ID}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --vnet-name "${VNET_NAME}" \
    --query "[?remoteVirtualNetwork.id=='${consumer_vnet_id}'] | length(@)" \
    --output tsv
)"

[[ "${local_peering_count}" != "0" ]] ||
  die "The DVWA-owned peering does not target ${consumer_vnet_id}. Add it to approved_remote_vnet_ids and apply Terraform first."

existing_peering_name="$(
  az network vnet peering list \
    --subscription "${consumer_subscription_id}" \
    --resource-group "${DVWA_CONSUMER_RESOURCE_GROUP}" \
    --vnet-name "${DVWA_CONSUMER_VNET_NAME}" \
    --query "[?remoteVirtualNetwork.id=='${dvwa_vnet_id}'].name | [0]" \
    --output tsv
)"

if [[ -n "${existing_peering_name}" ]]; then
  existing_remote_id="$(
    az network vnet peering show \
      --subscription "${consumer_subscription_id}" \
      --resource-group "${DVWA_CONSUMER_RESOURCE_GROUP}" \
      --vnet-name "${DVWA_CONSUMER_VNET_NAME}" \
      --name "${existing_peering_name}" \
      --query remoteVirtualNetwork.id \
      --output tsv
  )"
  [[ "${existing_remote_id}" == "${dvwa_vnet_id}" ]] ||
    die "Existing peering ${existing_peering_name} targets ${existing_remote_id}, not ${dvwa_vnet_id}."
  consumer_peering_name="${existing_peering_name}"
  info "Consumer peering ${consumer_peering_name} already targets DVWA; no creation needed."
else
  if [[ "${assume_yes}" != true ]]; then
    confirm_action \
      "PEER DVWA" \
      "This creates ${consumer_peering_name} on ${consumer_vnet_id}, targeting ${dvwa_vnet_id}."
  fi

  az network vnet peering create \
    --subscription "${consumer_subscription_id}" \
    --resource-group "${DVWA_CONSUMER_RESOURCE_GROUP}" \
    --vnet-name "${DVWA_CONSUMER_VNET_NAME}" \
    --name "${consumer_peering_name}" \
    --remote-vnet "${dvwa_vnet_id}" \
    --allow-vnet-access \
    --output none
fi

az network vnet peering show \
  --subscription "${consumer_subscription_id}" \
  --resource-group "${DVWA_CONSUMER_RESOURCE_GROUP}" \
  --vnet-name "${DVWA_CONSUMER_VNET_NAME}" \
  --name "${consumer_peering_name}" \
  --query '{name:name,state:peeringState,remote:remoteVirtualNetwork.id}' \
  --output table

info "The expected final peering state is Connected."
