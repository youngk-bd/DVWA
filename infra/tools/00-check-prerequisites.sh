#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: ./tools/00-check-prerequisites.sh

Performs read-only checks for required local commands, Azure authentication,
the target subscription, the SSH public key input, and local configuration.
EOF
  show_common_environment_help
  exit 0
fi

for command_name in az curl ssh-keygen terraform python3; do
  require_command "${command_name}"
done

ensure_azure_subscription
load_ssh_public_key

info "$(terraform version | sed -n '1p')"
info "Azure CLI $(az version --query '"azure-cli"' --output tsv)"

if [[ -f "${INFRA_DIR}/terraform.tfvars" ]]; then
  info "Found ${INFRA_DIR}/terraform.tfvars."
else
  warn "terraform.tfvars does not exist. Run 02-prepare-configuration.sh or provide all non-secret inputs with TF_VAR_* environment variables."
fi

info "Prerequisite checks passed."
