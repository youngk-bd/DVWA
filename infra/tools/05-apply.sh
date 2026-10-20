#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

plan_file="${INFRA_DIR}/dvwa.tfplan"
assume_yes=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)
      [[ $# -ge 2 ]] || die "--plan requires a file path."
      plan_file="$2"
      shift 2
      ;;
    --yes)
      assume_yes=true
      shift
      ;;
    --help)
      cat <<EOF
Usage: ./tools/05-apply.sh [--plan PATH] [--yes]

Applies a saved plan created by 04-plan.sh. The subscription binding is checked
before apply. Without --yes, the script requires the phrase APPLY DVWA.
EOF
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

if [[ "${plan_file}" != /* ]]; then
  plan_file="${INFRA_DIR}/${plan_file}"
fi

ensure_azure_subscription
load_ssh_public_key

[[ -f "${plan_file}" ]] || die "Saved plan not found: ${plan_file}. Run 04-plan.sh first."
verify_plan_subscription "${plan_file}"

if [[ "${assume_yes}" != true ]]; then
  confirm_action "APPLY DVWA" "This will create or change Azure resources in ${EXPECTED_SUBSCRIPTION_NAME}/${RESOURCE_GROUP_NAME}."
fi

# Terraform detaches separately managed data disks before deleting a VM.
# Stop writers and unmount first; otherwise even a retained disk can receive
# an unsafe hot detach during replacement or compute removal.
require_command python3
needs_quiesce="$(terraform_command show -json "${plan_file}" | python3 -c '
import json, sys
plan = json.load(sys.stdin)
print("true" if any(
    change["type"] in ("azurerm_linux_virtual_machine", "azurerm_virtual_machine_data_disk_attachment")
    and "delete" in change["change"]["actions"]
    for change in plan.get("resource_changes", [])
) else "false")
')"
if [[ "${needs_quiesce}" == true ]]; then
  power_state="$(az vm get-instance-view \
    --subscription "${ARM_SUBSCRIPTION_ID}" \
    --resource-group "${RESOURCE_GROUP_NAME}" --name "${VM_NAME}" \
    --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" --output tsv)"
  case "${power_state}" in
    PowerState/deallocated | PowerState/stopped)
      info "VM is already stopped; there are no guest disk writers."
      ;;
    PowerState/running)
      info "Stopping DVWA and unmounting its retained data disk before Terraform detaches it."
      quiesce_output="$(az vm run-command invoke \
        --subscription "${ARM_SUBSCRIPTION_ID}" \
        --resource-group "${RESOURCE_GROUP_NAME}" --name "${VM_NAME}" \
        --command-id RunShellScript \
        --scripts 'set -e; mountpoint -q /opt/dvwa || { echo "Migrate OS-disk data before replacing the VM." >&2; exit 1; }; systemctl stop dvwa-proxy.socket dvwa-proxy.service dvwa; systemctl stop docker.service docker.socket; sync; umount /opt/dvwa; echo DVWA_STORAGE_QUIESCED' \
        --query 'value[].message' --output tsv)"
      printf '%s\n' "${quiesce_output}"
      grep -Fx 'DVWA_STORAGE_QUIESCED' <<<"${quiesce_output}" >/dev/null ||
        die "Storage could not be quiesced; Terraform has not been applied."
      ;;
    *) die "Cannot safely replace the VM while its power state is '${power_state}'." ;;
  esac
fi

terraform_command apply -input=false "${plan_file}"
terraform_command output

info "Apply completed. Continue with 06-create-reciprocal-peering.sh when a consumer VNet is configured, then run 07-verify.sh."
