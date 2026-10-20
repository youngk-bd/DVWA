#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

test_http=false
skip_run_command=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test-http)
      test_http=true
      shift
      ;;
    --skip-run-command)
      skip_run_command=true
      shift
      ;;
    --help)
      cat <<EOF
Usage: ./tools/07-verify.sh [--test-http] [--skip-run-command]

Confirms the VM NIC has no public IP, reports power/extension state, and uses
Azure Run Command to wait for cloud-init and inspect DVWA containers.

--test-http additionally resolves and requests ${PRIVATE_DVWA_URL} from this
machine. That succeeds only when this machine has approved private routing.
EOF
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

ensure_azure_subscription

nic_id="$(
  az vm show \
    --subscription "${ARM_SUBSCRIPTION_ID}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --name "${VM_NAME}" \
    --query 'networkProfile.networkInterfaces[0].id' \
    --output tsv
)"

[[ -n "${nic_id}" ]] || die "VM or primary NIC was not found."

public_ip_id="$(
  az network nic show \
    --subscription "${ARM_SUBSCRIPTION_ID}" \
    --ids "${nic_id}" \
    --query 'ipConfigurations[0].publicIPAddress.id' \
    --output tsv
)"

if [[ -n "${public_ip_id}" && "${public_ip_id}" != "null" ]]; then
  die "Security invariant failed: VM NIC has public IP association ${public_ip_id}."
fi

private_ip="$(
  az network nic show \
    --subscription "${ARM_SUBSCRIPTION_ID}" \
    --ids "${nic_id}" \
    --query 'ipConfigurations[0].privateIPAddress' \
    --output tsv
)"

power_state="$(
  az vm get-instance-view \
    --subscription "${ARM_SUBSCRIPTION_ID}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --name "${VM_NAME}" \
    --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" \
    --output tsv
)"

info "VM private IP: ${private_ip}"
info "VM NIC public IP: none"
info "VM power state: ${power_state}"

az vm extension list \
  --subscription "${ARM_SUBSCRIPTION_ID}" \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --vm-name "${VM_NAME}" \
  --query '[].{name:name,state:provisioningState,publisher:publisher}' \
  --output table

if [[ "${skip_run_command}" != true ]]; then
  [[ "${power_state}" == "VM running" ]] ||
    die "VM is not running. Run 09-activate-vm.sh before guest verification."

  verification_output="$(az vm run-command invoke \
    --subscription "${ARM_SUBSCRIPTION_ID}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --name "${VM_NAME}" \
    --command-id RunShellScript \
    --scripts 'set -e; cloud-init status --wait; /usr/local/sbin/dvwa-verify' \
    --query 'value[].message' \
    --output tsv)"
  printf '%s\n' "${verification_output}"
  # Azure CLI may exit zero even when the guest script failed.
  grep -Fx 'DVWA_VERIFY_OK' <<<"${verification_output}" >/dev/null ||
    die "Guest verification failed. Check cloud-init, data disk mount, database health, and HTTP."
fi

if [[ "${test_http}" == true ]]; then
  require_command curl
  info "Testing private DNS and HTTP from this machine."
  curl --fail --show-error --silent --head --connect-timeout 10 "${PRIVATE_DVWA_URL}"
fi

info "Verification completed. Use --test-http from an approved privately routed client to test the application path."
