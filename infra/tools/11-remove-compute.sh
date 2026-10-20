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
Usage: ./tools/11-remove-compute.sh [--yes]

Plans and applies vm_deployed=false. This removes the VM, NIC, extensions, DNS
record, role assignments, NAT Gateway, and NAT public IP while retaining the
managed data disk, network, private DNS zone, and monitoring workspace.
EOF
    exit 0
    ;;
  "") ;;
  *) die "Unknown argument: ${1}" ;;
esac

ensure_azure_subscription
load_ssh_public_key

plan_file="${INFRA_DIR}/dvwa-remove-compute.tfplan"
lifecycle_file="${INFRA_DIR}/lifecycle.auto.tfvars"
terraform_command init -input=false
terraform_command plan -input=false -var='vm_deployed=false' -out="${plan_file}"
chmod 600 "${plan_file}"
bind_plan_to_subscription "${plan_file}"
terraform_command show -no-color "${plan_file}"

if [[ "${assume_yes}" != true ]]; then
  confirm_action "REMOVE DVWA COMPUTE" "Review the plan above. This removes compute but retains disk-dvwa-data."
fi

printf 'vm_deployed = false\n' >"${lifecycle_file}"
chmod 600 "${lifecycle_file}"
info "Persisted vm_deployed=false in ${lifecycle_file}."

verify_plan_subscription "${plan_file}"
terraform_command apply -input=false "${plan_file}"

info "DVWA compute was removed; persistent data and foundational private infrastructure remain."
