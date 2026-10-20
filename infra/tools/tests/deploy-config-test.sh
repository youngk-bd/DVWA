#!/usr/bin/env bash

# Offline regression test for deploy.sh configuration generation. No Azure or
# Terraform provider calls are made; an Azure CLI stub provides deterministic
# account data while the installed Terraform binary parses and formats HCL.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_INFRA_DIR="$(cd "${TEST_DIR}/../.." && pwd)"
temporary_root="$(mktemp -d)"

cleanup() {
  rm -rf -- "${temporary_root}"
}
trap cleanup EXIT

mkdir -p \
  "${temporary_root}/bin" \
  "${temporary_root}/home" \
  "${temporary_root}/infra/tools/lib"

cp "${SOURCE_INFRA_DIR}/deploy.sh" "${temporary_root}/infra/deploy.sh"
cp "${SOURCE_INFRA_DIR}/terraform.tfvars.example" "${temporary_root}/infra/terraform.tfvars.example"
cp "${SOURCE_INFRA_DIR}/tools/00-check-prerequisites.sh" "${temporary_root}/infra/tools/00-check-prerequisites.sh"
cp "${SOURCE_INFRA_DIR}/tools/lib/common.sh" "${temporary_root}/infra/tools/lib/common.sh"

cat >"${temporary_root}/bin/az" <<'AZURE_STUB'
#!/usr/bin/env bash
set -euo pipefail
arguments=" $* "
case "${1:-} ${2:-}" in
  "account show")
    if [[ "${arguments}" == *" --query name "* ]]; then
      printf 'BYTEDEFENSE_INFRA_NON_PROD\n'
    elif [[ "${arguments}" == *" --query id "* ]]; then
      printf '00000000-0000-0000-0000-000000000001\n'
    elif [[ "${arguments}" == *" --query user.name "* ]]; then
      printf 'test@example.invalid\n'
    else
      printf '{"id":"00000000-0000-0000-0000-000000000001","name":"BYTEDEFENSE_INFRA_NON_PROD"}\n'
    fi
    ;;
  "account set") ;;
  "account list") printf '00000000-0000-0000-0000-000000000001\n' ;;
  "ad signed-in-user") printf '00000000-0000-0000-0000-000000000002\n' ;;
  "network vnet") printf '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-test-consumer/providers/Microsoft.Network/virtualNetworks/vnet-test-consumer\tvnet-test-consumer\trg-test-consumer\n' ;;
  version*) printf '2.81.0\n' ;;
  *) printf 'Unexpected az stub invocation: %s\n' "$*" >&2; exit 1 ;;
esac
AZURE_STUB

chmod 755 \
  "${temporary_root}/bin/az" \
  "${temporary_root}/infra/deploy.sh" \
  "${temporary_root}/infra/tools/00-check-prerequisites.sh"

if ! PATH="${temporary_root}/bin:${PATH}" \
  HOME="${temporary_root}/home" \
  ARM_SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000001" \
  ARM_CLIENT_SECRET="must-not-be-written" \
  TF_VAR_admin_ssh_public_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINOkakOi2wFpVcgCXV0kkrKCCKZmzI7Y/mHwMk+DC6EH deploy-test" \
  DVWA_LOCATION="westus3" \
  DVWA_VM_SIZE="Standard_B2s" \
  DVWA_ENABLE_ENCRYPTION_AT_HOST="false" \
  DVWA_CONSUMER_VNET_ID="/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-test-consumer/providers/Microsoft.Network/virtualNetworks/vnet-test-consumer" \
  DVWA_APPLICATION_SOURCE_CIDRS="10.20.3.0/24,10.20.4.0/24" \
  DVWA_SSH_SOURCE_CIDRS="10.20.8.9/32" \
  DVWA_ADMIN_PRINCIPAL_IDS="00000000-0000-0000-0000-000000000002" \
  DVWA_OWNER="security-test" \
  DVWA_COST_CENTER="detection" \
    "${temporary_root}/infra/deploy.sh" \
      --yes \
      --configure-only \
      --reconfigure \
      >"${temporary_root}/deploy.log" 2>&1; then
  cat "${temporary_root}/deploy.log" >&2
  exit 1
fi

configuration_file="${temporary_root}/infra/terraform.tfvars"
lifecycle_file="${temporary_root}/infra/lifecycle.auto.tfvars"

[[ -f "${configuration_file}" ]] || { printf 'terraform.tfvars was not generated\n' >&2; exit 1; }
terraform fmt -check "${configuration_file}" >/dev/null
[[ "$(stat -f '%Lp' "${configuration_file}" 2>/dev/null || stat -c '%a' "${configuration_file}")" == "600" ]] || {
  printf 'terraform.tfvars does not have mode 0600\n' >&2
  exit 1
}

grep -q 'location.*"westus3"' "${configuration_file}"
grep -q 'application_allowed_source_cidrs = \["10.20.3.0/24", "10.20.4.0/24"\]' "${configuration_file}"
grep -q 'ssh_allowed_source_cidrs.*\["10.20.8.9/32"\]' "${configuration_file}"
grep -q 'vm_admin_principal_ids.*00000000-0000-0000-0000-000000000002' "${configuration_file}"
grep -q 'approved_remote_vnet_ids' "${configuration_file}"
grep -q 'vnet-test-consumer' "${configuration_file}"
grep -q 'owner.*"security-test"' "${configuration_file}"
grep -q '^vm_deployed = true$' "${lifecycle_file}"

grep -F "grep -Fx 'azurerm_managed_disk.data' >/dev/null" \
  "${temporary_root}/infra/deploy.sh" >/dev/null || {
  printf 'Fresh-deployment detection must consume the full Terraform state stream under pipefail\n' >&2
  exit 1
}

if grep -q 'must-not-be-written' "${configuration_file}"; then
  printf 'Sensitive ARM_CLIENT_SECRET leaked into terraform.tfvars\n' >&2
  exit 1
fi

printf 'deploy.sh offline configuration test passed\n'
