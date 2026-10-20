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
Usage: ./tools/12-restore-compute.sh [--yes]

Plans and applies vm_deployed=true, rebuilding the VM/NIC/extensions/NAT and
reattaching the retained data disk. The normal environment and Terraform input
requirements apply.
EOF
    exit 0
    ;;
  "") ;;
  *) die "Unknown argument: ${1}" ;;
esac

ensure_azure_subscription
load_ssh_public_key

plan_file="${INFRA_DIR}/dvwa-restore-compute.tfplan"
lifecycle_file="${INFRA_DIR}/lifecycle.auto.tfvars"
terraform_command init -input=false
terraform_command plan -input=false -var='vm_deployed=true' -out="${plan_file}"
chmod 600 "${plan_file}"
bind_plan_to_subscription "${plan_file}"
terraform_command show -no-color "${plan_file}"

if [[ "${assume_yes}" != true ]]; then
  confirm_action "RESTORE DVWA COMPUTE" "Review the plan above. This recreates billable compute and outbound NAT resources."
fi

printf 'vm_deployed = true\n' >"${lifecycle_file}"
chmod 600 "${lifecycle_file}"
info "Persisted vm_deployed=true in ${lifecycle_file}."

verify_plan_subscription "${plan_file}"
terraform_command apply -input=false "${plan_file}"

info "DVWA compute was restored. Run 07-verify.sh before use."
