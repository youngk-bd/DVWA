#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

force=false

case "${1:-}" in
  --force) force=true ;;
  --help)
    cat <<'EOF'
Usage: ./tools/02-prepare-configuration.sh [--force]

Copies terraform.tfvars.example to terraform.tfvars with mode 0600. The file
contains non-secret settings only. --force replaces an existing file.

Afterward, configure the approved application/SSH CIDRs, Entra object IDs,
consumer VNet IDs, region, size, and tags. Keep credentials and private keys in
environment variables, never in terraform.tfvars.
EOF
    exit 0
    ;;
  "") ;;
  *) die "Unknown argument: ${1}" ;;
esac

destination="${INFRA_DIR}/terraform.tfvars"
source_file="${INFRA_DIR}/terraform.tfvars.example"

[[ -f "${source_file}" ]] || die "Configuration example not found: ${source_file}"

if [[ -e "${destination}" && "${force}" != true ]]; then
  die "${destination} already exists. Use --force only if replacing it is intentional."
fi

cp "${source_file}" "${destination}"
chmod 600 "${destination}"

info "Created ${destination}."
cat <<EOF
Next, edit that file and set:
  application_allowed_source_cidrs
  ssh_allowed_source_cidrs
  vm_admin_principal_ids
  approved_remote_vnet_ids
  additional_private_dns_vnet_links

The caller ranges need private routing into 10.70.0.0/16. Do not add
0.0.0.0/0 or ::/0. The default empty lists intentionally permit no access.
EOF
