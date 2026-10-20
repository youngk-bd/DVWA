#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: ./tools/03-validate.sh

Initializes Terraform, checks formatting and provider schemas, and executes the
offline mocked secure-default and compute-removed plan tests. No Azure workload
resources are changed.
EOF
  exit 0
fi

ensure_azure_subscription
load_ssh_public_key

bash "${TOOLS_DIR}/tests/storage-safety-test.sh"
bash "${TOOLS_DIR}/tests/apply-storage-test.sh"
bash -n "${INFRA_DIR}"/guest/*.sh
terraform_command init -input=false
terraform_command fmt -recursive -check -diff
terraform_command validate -no-color
terraform_command test -no-color

info "Terraform validation and tests passed."
