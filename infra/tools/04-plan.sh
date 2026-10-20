#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

plan_file="${INFRA_DIR}/dvwa.tfplan"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      [[ $# -ge 2 ]] || die "--out requires a file path."
      plan_file="$2"
      shift 2
      ;;
    --help)
      cat <<EOF
Usage: ./tools/04-plan.sh [--out PATH]

Creates a saved Terraform plan (default: ${INFRA_DIR}/dvwa.tfplan), binds it to
the validated subscription ID, and prints the plan for review. This performs
Azure reads but makes no Azure changes.
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

terraform_command init -input=false
terraform_command plan -input=false -out="${plan_file}"
chmod 600 "${plan_file}"
bind_plan_to_subscription "${plan_file}"

terraform_command show -no-color "${plan_file}"

info "Saved plan: ${plan_file}"
info "Review that the VM NIC has no public IP and every workload resource targets ${RESOURCE_GROUP_NAME}."
