#!/usr/bin/env bash

# Human-friendly, single-entry deployment pipeline for the private DVWA stack.

set -euo pipefail

INFRA_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/lib/common.sh
source "${INFRA_SCRIPT_DIR}/tools/lib/common.sh"

assume_yes=false
configure_only=false
force_database_init=false
install_missing=false
plan_only=false
reconfigure=false
skip_database_init=false
skip_provider_registration=false

usage() {
  cat <<'EOF'
Usage: ./infra/deploy.sh [options]

One-command deployment pipeline for the private Azure DVWA test server. It can
authenticate/select the expected subscription, register providers, locate or
create an SSH public key, discover a consumer VNet/subnet, atomically generate
terraform.tfvars, validate/test Terraform, show and apply a bound plan, create
reciprocal peerings, verify the VM, and initialize the DVWA database.

Options:
  --yes                         Use secure defaults and skip confirmation prompts.
  --reconfigure                 Regenerate terraform.tfvars even when it exists.
  --configure-only              Generate configuration and stop before Terraform.
  --plan-only                   Validate and create a plan without applying it.
  --install-missing             Install missing CLI tools with Homebrew when possible.
  --initialize-database         Initialize/reset DVWA even for an existing deployment.
  --skip-database-init          Never initialize/reset the DVWA database.
  --skip-provider-registration  Do not register Azure resource providers.
  --help                        Show this help.

Non-interactive configuration environment:
  DVWA_LOCATION                         Default: eastus2
  DVWA_VM_SIZE                          Default: Standard_D2s_v7
  DVWA_AVAILABILITY_ZONE                Empty, 1, 2, or 3
  DVWA_ENABLE_ENCRYPTION_AT_HOST        true or false; default false
  DVWA_CONSUMER_VNET_ID                 Approved consumer VNet resource ID
  DVWA_APPLICATION_SOURCE_CIDRS         Comma-separated private CIDRs
  DVWA_SSH_SOURCE_CIDRS                 Comma-separated private CIDRs
  DVWA_ADMIN_PRINCIPAL_IDS              Comma-separated Entra object IDs
  DVWA_GRANT_CURRENT_USER_VM_ADMIN      true or false
  DVWA_OWNER                            owner tag
  DVWA_COST_CENTER                      cost-center tag
  DVWA_INITIALIZE_DATABASE              true or false
  DVWA_SSH_KEY_PATH                     Key path to use/create if no key env is set

Azure credentials remain in ARM_* environment variables. The SSH public key
may be supplied through TF_VAR_admin_ssh_public_key or
DVWA_SSH_PUBLIC_KEY_FILE. No credential or private key enters terraform.tfvars.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      assume_yes=true
      shift
      ;;
    --reconfigure)
      reconfigure=true
      shift
      ;;
    --configure-only)
      configure_only=true
      shift
      ;;
    --plan-only)
      plan_only=true
      shift
      ;;
    --install-missing)
      install_missing=true
      shift
      ;;
    --initialize-database)
      force_database_init=true
      shift
      ;;
    --skip-database-init)
      skip_database_init=true
      shift
      ;;
    --skip-provider-registration)
      skip_provider_registration=true
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${force_database_init}" != true || "${skip_database_init}" != true ]] ||
  die "--initialize-database and --skip-database-init cannot be used together."

prompt_value() {
  local label="$1"
  local default_value="$2"
  local supplied_value="${3:-}"
  local response

  if [[ -n "${supplied_value}" ]]; then
    printf '%s' "${supplied_value}"
    return
  fi

  if [[ "${assume_yes}" == true ]]; then
    printf '%s' "${default_value}"
    return
  fi

  [[ -t 0 ]] || die "${label} requires input. Set its documented environment variable or use a terminal."
  printf '%s [%s]: ' "${label}" "${default_value}" >&2
  IFS= read -r response
  printf '%s' "${response:-${default_value}}"
}

prompt_yes_no() {
  local label="$1"
  local default_answer="$2"
  local supplied_answer="${3:-}"
  local answer

  if [[ -n "${supplied_answer}" ]]; then
    answer="${supplied_answer}"
  elif [[ "${assume_yes}" == true ]]; then
    answer="${default_answer}"
  else
    [[ -t 0 ]] || die "${label} requires input. Supply its documented environment variable or use a terminal."
    if [[ "${default_answer}" == "true" ]]; then
      printf '%s [Y/n]: ' "${label}" >&2
    else
      printf '%s [y/N]: ' "${label}" >&2
    fi
    IFS= read -r answer
    [[ -n "${answer}" ]] || answer="${default_answer}"
  fi

  case "${answer}" in
    true | TRUE | yes | YES | y | Y | 1) return 0 ;;
    false | FALSE | no | NO | n | N | 0) return 1 ;;
    *) die "Expected yes/no value for: ${label}" ;;
  esac
}

trim_value() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

split_csv() {
  local csv_value="$1"
  local item
  local raw_values=()

  SPLIT_VALUES=()
  [[ -n "${csv_value}" ]] || return 0
  IFS=',' read -r -a raw_values <<<"${csv_value}"
  for item in "${raw_values[@]}"; do
    item="$(trim_value "${item}")"
    [[ -n "${item}" ]] && SPLIT_VALUES+=("${item}")
  done
}

hcl_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '"%s"' "${value}"
}

render_hcl_csv_list() {
  local csv_value="$1"
  local separator=""
  local item

  split_csv "${csv_value}"
  printf '['
  for item in "${SPLIT_VALUES[@]}"; do
    printf '%s' "${separator}"
    hcl_quote "${item}"
    separator=', '
  done
  printf ']'
}

resource_id_segment() {
  local resource_id="$1"
  local segment_name="$2"
  printf '%s\n' "${resource_id}" | awk -F/ -v wanted="${segment_name}" '
    { for (field_index = 1; field_index <= NF; field_index++) if (tolower($field_index) == tolower(wanted)) { print $(field_index + 1); exit } }
  '
}

install_missing_commands() {
  local command_name
  local missing_commands=()

  for command_name in az curl ssh-keygen terraform python3; do
    command -v "${command_name}" >/dev/null 2>&1 || missing_commands+=("${command_name}")
  done
  [[ ${#missing_commands[@]} -gt 0 ]] || return 0

  warn "Missing required commands: ${missing_commands[*]}"
  if [[ "${install_missing}" != true ]]; then
    if ! prompt_yes_no "Install missing tools with Homebrew" false; then
      die "Install the missing commands or rerun with --install-missing."
    fi
  fi

  command -v brew >/dev/null 2>&1 ||
    die "Automatic installation currently supports Homebrew. Install the missing tools for this platform and rerun."

  for command_name in "${missing_commands[@]}"; do
    case "${command_name}" in
      az) brew install azure-cli ;;
      terraform)
        brew tap hashicorp/tap
        brew install hashicorp/tap/terraform
        ;;
      curl) brew install curl ;;
      ssh-keygen) brew install openssh ;;
      python3) brew install python ;;
    esac
  done
}

login_and_select_subscription() {
  local matching_subscription_ids

  if ! az account show >/dev/null 2>&1; then
    [[ "${assume_yes}" != true ]] ||
      die "Azure CLI is not authenticated. Authenticate before using --yes."
    info "Azure CLI login is required."
    az login
  fi

  if [[ -z "${ARM_SUBSCRIPTION_ID:-}" ]]; then
    matching_subscription_ids="$(
      az account list \
        --all \
        --query "[?name=='${EXPECTED_SUBSCRIPTION_NAME}'].id" \
        --output tsv
    )"
    [[ -n "${matching_subscription_ids}" ]] ||
      die "No accessible subscription is named ${EXPECTED_SUBSCRIPTION_NAME}."

    ARM_SUBSCRIPTION_ID="$(printf '%s\n' "${matching_subscription_ids}" | sed -n '1p')"
    export ARM_SUBSCRIPTION_ID
  fi

  az account set --subscription "${ARM_SUBSCRIPTION_ID}"
  ensure_azure_subscription
}

prepare_ssh_public_key() {
  local default_public_key_path=""
  local private_key_path
  local public_key_path

  if [[ -n "${TF_VAR_admin_ssh_public_key:-}" || -n "${DVWA_SSH_PUBLIC_KEY_FILE:-}" ]]; then
    load_ssh_public_key
    return
  fi

  for candidate in \
    "${HOME}/.ssh/dvwa_azure.pub" \
    "${HOME}/.ssh/id_ed25519.pub" \
    "${HOME}/.ssh/id_rsa.pub"; do
    if [[ -f "${candidate}" ]]; then
      default_public_key_path="${candidate}"
      break
    fi
  done
  [[ -n "${default_public_key_path}" ]] || default_public_key_path="${HOME}/.ssh/dvwa_azure.pub"

  public_key_path="$(
    prompt_value \
      "SSH public key file (an absent path will be generated)" \
      "${default_public_key_path}" \
      "${DVWA_SSH_KEY_PATH:-}"
  )"

  if [[ "${public_key_path}" != *.pub && -f "${public_key_path}.pub" ]]; then
    public_key_path="${public_key_path}.pub"
  fi

  if [[ ! -f "${public_key_path}" ]]; then
    if [[ "${public_key_path}" == *.pub ]]; then
      private_key_path="${public_key_path%.pub}"
    else
      private_key_path="${public_key_path}"
      public_key_path="${public_key_path}.pub"
    fi

    if [[ "${assume_yes}" != true ]]; then
      prompt_yes_no "Generate a dedicated passwordless Ed25519 key at ${private_key_path}" true ||
        die "An SSH public key is required for break-glass VM access."
    fi
    mkdir -p "$(dirname "${private_key_path}")"
    ssh-keygen -q -t ed25519 -N '' -C dvwa-azure -f "${private_key_path}"
    chmod 600 "${private_key_path}"
    chmod 644 "${public_key_path}"
    info "Generated dedicated SSH key pair at ${private_key_path}(.pub)."
  fi

  DVWA_SSH_PUBLIC_KEY_FILE="${public_key_path}"
  export DVWA_SSH_PUBLIC_KEY_FILE
  load_ssh_public_key
}

select_consumer_vnet() {
  local index
  local selection
  local vnet_id
  local vnet_name
  local vnet_prefix
  local vnet_resource_group
  local vnet_ids=()
  local vnet_labels=()

  CONSUMER_VNET_ID="${DVWA_CONSUMER_VNET_ID:-}"
  if [[ -z "${CONSUMER_VNET_ID}" ]]; then
    if [[ "${assume_yes}" == true ]]; then
      warn "DVWA_CONSUMER_VNET_ID is unset; secure non-interactive deployment will create no VNet peering or HTTP ingress."
      return
    fi
    if ! prompt_yes_no "Connect an existing Azure VNet to DVWA privately" true; then
      return
    fi

    while IFS=$'\t' read -r vnet_name vnet_resource_group vnet_prefix vnet_id; do
      [[ -n "${vnet_id}" ]] || continue
      vnet_ids+=("${vnet_id}")
      vnet_labels+=("${vnet_name} | ${vnet_resource_group} | ${vnet_prefix}")
    done < <(
      az network vnet list \
        --subscription "${ARM_SUBSCRIPTION_ID}" \
        --query "[?name!='${VNET_NAME}'].[name,resourceGroup,addressSpace.addressPrefixes[0],id]" \
        --output tsv
    )

    if [[ ${#vnet_ids[@]} -eq 0 ]]; then
      CONSUMER_VNET_ID="$(prompt_value "Consumer VNet resource ID" "" "")"
    else
      printf '\nAccessible VNets:\n' >&2
      for index in "${!vnet_ids[@]}"; do
        printf '  %d) %s\n' "$((index + 1))" "${vnet_labels[${index}]}" >&2
      done
      selection="$(prompt_value "Consumer VNet number" "1" "")"
      [[ "${selection}" =~ ^[0-9]+$ ]] || die "Consumer VNet selection must be a number."
      ((selection >= 1 && selection <= ${#vnet_ids[@]})) || die "Consumer VNet selection is out of range."
      CONSUMER_VNET_ID="${vnet_ids[$((selection - 1))]}"
    fi
  fi

  [[ -n "${CONSUMER_VNET_ID}" ]] || return 0
  consumer_metadata="$(
    az network vnet show \
      --ids "${CONSUMER_VNET_ID}" \
      --query '[id,name,resourceGroup]' \
      --output tsv
  )"
  IFS=$'\t' read -r CONSUMER_VNET_ID CONSUMER_VNET_NAME CONSUMER_RESOURCE_GROUP <<<"${consumer_metadata}"
  CONSUMER_SUBSCRIPTION_ID="$(resource_id_segment "${CONSUMER_VNET_ID}" subscriptions)"

  info "Selected consumer VNet ${CONSUMER_VNET_NAME} (${CONSUMER_VNET_ID})."
}

select_application_source_cidrs() {
  local index
  local selection
  local subnet_id
  local subnet_name
  local subnet_prefix
  local subnet_ids=()
  local subnet_labels=()
  local subnet_prefixes=()

  APPLICATION_SOURCE_CIDRS="${DVWA_APPLICATION_SOURCE_CIDRS:-}"
  [[ -z "${APPLICATION_SOURCE_CIDRS}" ]] || return 0

  if [[ -n "${CONSUMER_VNET_ID:-}" ]]; then
    if [[ "${assume_yes}" == true ]]; then
      warn "DVWA_APPLICATION_SOURCE_CIDRS is unset; secure non-interactive deployment will not guess a consumer subnet, so HTTP ingress remains closed."
      return
    fi
    while IFS=$'\t' read -r subnet_name subnet_prefix subnet_id; do
      case "${subnet_name}" in
        GatewaySubnet | AzureBastionSubnet | AzureFirewallSubnet | RouteServerSubnet) continue ;;
      esac
      [[ -n "${subnet_id}" && -n "${subnet_prefix}" ]] || continue
      subnet_ids+=("${subnet_id}")
      subnet_prefixes+=("${subnet_prefix}")
      subnet_labels+=("${subnet_name} | ${subnet_prefix}")
    done < <(
      az network vnet subnet list \
        --subscription "${CONSUMER_SUBSCRIPTION_ID}" \
        --resource-group "${CONSUMER_RESOURCE_GROUP}" \
        --vnet-name "${CONSUMER_VNET_NAME}" \
        --query "[].[name, addressPrefixes[0] || addressPrefix, id]" \
        --output tsv
    )

    if [[ ${#subnet_ids[@]} -gt 0 ]]; then
      printf '\nConsumer subnets:\n' >&2
      for index in "${!subnet_ids[@]}"; do
        printf '  %d) %s\n' "$((index + 1))" "${subnet_labels[${index}]}" >&2
      done
      selection="$(prompt_value "Subnet allowed to reach DVWA HTTP" "1" "")"
      [[ "${selection}" =~ ^[0-9]+$ ]] || die "Subnet selection must be a number."
      ((selection >= 1 && selection <= ${#subnet_ids[@]})) || die "Subnet selection is out of range."
      APPLICATION_SOURCE_CIDRS="${subnet_prefixes[$((selection - 1))]}"
      return
    fi
  fi

  APPLICATION_SOURCE_CIDRS="$(prompt_value "Approved HTTP source CIDRs (comma-separated; empty closes HTTP)" "" "")"
}

validate_scoped_cidrs() {
  local label="$1"
  local csv_value="$2"
  local cidr

  split_csv "${csv_value}"
  for cidr in "${SPLIT_VALUES[@]}"; do
    [[ "${cidr}" != "0.0.0.0/0" && "${cidr}" != "::/0" ]] ||
      die "${label} cannot contain an Internet-wide CIDR (${cidr})."
  done
}

write_terraform_configuration() {
  local admin_principal_ids
  local availability_zone
  local configuration_file="${INFRA_DIR}/terraform.tfvars"
  local cost_center
  local current_principal_id=""
  local encryption_at_host
  local formatted_file
  local location
  local owner
  local temporary_file
  local vm_size

  location="$(prompt_value "Azure region" "eastus2" "${DVWA_LOCATION:-}")"
  vm_size="$(prompt_value "VM size" "Standard_D2s_v7" "${DVWA_VM_SIZE:-}")"
  availability_zone="$(prompt_value "Availability zone (empty, 1, 2, or 3)" "" "${DVWA_AVAILABILITY_ZONE:-}")"

  if prompt_yes_no "Enable Azure encryption at host (requires registered feature and supported SKU)" false "${DVWA_ENABLE_ENCRYPTION_AT_HOST:-}"; then
    encryption_at_host=true
  else
    encryption_at_host=false
  fi

  select_consumer_vnet
  select_application_source_cidrs
  SSH_SOURCE_CIDRS="$(prompt_value "Approved SSH source CIDRs (comma-separated; empty closes SSH)" "" "${DVWA_SSH_SOURCE_CIDRS:-}")"

  validate_scoped_cidrs "HTTP sources" "${APPLICATION_SOURCE_CIDRS}"
  validate_scoped_cidrs "SSH sources" "${SSH_SOURCE_CIDRS}"

  admin_principal_ids="${DVWA_ADMIN_PRINCIPAL_IDS:-}"
  if [[ -z "${admin_principal_ids}" ]]; then
    current_principal_id="$(az ad signed-in-user show --query id --output tsv 2>/dev/null || true)"
    if [[ -n "${current_principal_id}" ]] &&
      prompt_yes_no "Grant the current Entra user VM Administrator Login" true "${DVWA_GRANT_CURRENT_USER_VM_ADMIN:-}"; then
      admin_principal_ids="${current_principal_id}"
    fi
  fi

  owner="$(
    prompt_value \
      "Owner tag" \
      "$(az account show --query user.name --output tsv)" \
      "${DVWA_OWNER:-}"
  )"
  cost_center="$(prompt_value "Cost-center tag" "security-detection" "${DVWA_COST_CENTER:-}")"

  temporary_file="$(mktemp "${INFRA_DIR}/terraform.tfvars.tmp.XXXXXX")"
  {
    printf '# Generated by infra/deploy.sh on %s. Non-secret values only.\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'location          = '; hcl_quote "${location}"; printf '\n'
    printf 'vm_size           = '; hcl_quote "${vm_size}"; printf '\n'
    if [[ -n "${availability_zone}" ]]; then
      printf 'availability_zone = '; hcl_quote "${availability_zone}"; printf '\n'
    else
      printf 'availability_zone = null\n'
    fi
    printf 'encryption_at_host_enabled = %s\n\n' "${encryption_at_host}"
    printf 'application_allowed_source_cidrs = '; render_hcl_csv_list "${APPLICATION_SOURCE_CIDRS}"; printf '\n'
    printf 'ssh_allowed_source_cidrs         = '; render_hcl_csv_list "${SSH_SOURCE_CIDRS}"; printf '\n'
    printf 'vm_admin_principal_ids           = '; render_hcl_csv_list "${admin_principal_ids}"; printf '\n\n'
    if [[ -n "${CONSUMER_VNET_ID:-}" ]]; then
      printf 'approved_remote_vnet_ids = {\n  detector = '; hcl_quote "${CONSUMER_VNET_ID}"; printf '\n}\n\n'
      printf 'additional_private_dns_vnet_links = {\n  detector = '; hcl_quote "${CONSUMER_VNET_ID}"; printf '\n}\n\n'
    else
      printf 'approved_remote_vnet_ids            = {}\n'
      printf 'additional_private_dns_vnet_links   = {}\n\n'
    fi
    printf 'tags = {\n  owner       = '; hcl_quote "${owner}"; printf '\n  cost-center = '; hcl_quote "${cost_center}"; printf '\n}\n'
  } >"${temporary_file}"
  formatted_file="$(mktemp "${INFRA_DIR}/terraform.tfvars.formatted.XXXXXX")"
  if ! terraform fmt - <"${temporary_file}" >"${formatted_file}"; then
    rm -f -- "${temporary_file}" "${formatted_file}"
    die "Terraform could not parse the generated configuration."
  fi
  mv "${formatted_file}" "${temporary_file}"
  chmod 600 "${temporary_file}"

  if [[ -f "${configuration_file}" ]]; then
    cp "${configuration_file}" "${configuration_file}.backup"
    chmod 600 "${configuration_file}.backup"
    info "Backed up the previous configuration to ${configuration_file}.backup."
  fi
  mv "${temporary_file}" "${configuration_file}"
  chmod 600 "${configuration_file}"
  info "Generated ${configuration_file} without credential or private-key material."
}

configuration_overrides_present() {
  local variable_name
  for variable_name in \
    DVWA_LOCATION \
    DVWA_VM_SIZE \
    DVWA_AVAILABILITY_ZONE \
    DVWA_ENABLE_ENCRYPTION_AT_HOST \
    DVWA_CONSUMER_VNET_ID \
    DVWA_APPLICATION_SOURCE_CIDRS \
    DVWA_SSH_SOURCE_CIDRS \
    DVWA_ADMIN_PRINCIPAL_IDS \
    DVWA_GRANT_CURRENT_USER_VM_ADMIN \
    DVWA_OWNER \
    DVWA_COST_CENTER; do
    [[ -n "${!variable_name:-}" ]] && return 0
  done
  return 1
}

configure_if_needed() {
  local configuration_file="${INFRA_DIR}/terraform.tfvars"
  local regenerate=false

  if [[ ! -f "${configuration_file}" || "${reconfigure}" == true ]]; then
    regenerate=true
  elif configuration_overrides_present; then
    info "Configuration environment overrides were supplied; terraform.tfvars will be regenerated."
    regenerate=true
  elif [[ "${assume_yes}" != true ]] &&
    ! prompt_yes_no "Reuse the existing terraform.tfvars without changes" true; then
    regenerate=true
  fi

  if [[ "${regenerate}" == true ]]; then
    write_terraform_configuration
  else
    info "Reusing ${configuration_file}. Use --reconfigure to regenerate it."
  fi

  printf 'vm_deployed = true\n' >"${INFRA_DIR}/lifecycle.auto.tfvars"
  chmod 600 "${INFRA_DIR}/lifecycle.auto.tfvars"
}

reconcile_reciprocal_peerings() {
  local remote_vnet_id

  while IFS= read -r remote_vnet_id; do
    [[ -n "${remote_vnet_id}" ]] || continue
    DVWA_CONSUMER_SUBSCRIPTION_ID="$(resource_id_segment "${remote_vnet_id}" subscriptions)"
    DVWA_CONSUMER_RESOURCE_GROUP="$(resource_id_segment "${remote_vnet_id}" resourceGroups)"
    DVWA_CONSUMER_VNET_NAME="$(resource_id_segment "${remote_vnet_id}" virtualNetworks)"
    export DVWA_CONSUMER_SUBSCRIPTION_ID DVWA_CONSUMER_RESOURCE_GROUP DVWA_CONSUMER_VNET_NAME
    "${TOOLS_DIR}/06-create-reciprocal-peering.sh" --yes
  done < <(
    az network vnet peering list \
      --subscription "${ARM_SUBSCRIPTION_ID}" \
      --resource-group "${RESOURCE_GROUP_NAME}" \
      --vnet-name "${VNET_NAME}" \
      --query '[].remoteVirtualNetwork.id' \
      --output tsv
  )
}

should_initialize_database() {
  if [[ "${skip_database_init}" == true ]]; then
    return 1
  fi
  if [[ "${force_database_init}" == true ]]; then
    return 0
  fi
  if [[ -n "${DVWA_INITIALIZE_DATABASE:-}" ]]; then
    prompt_yes_no "Initialize/reset the DVWA database" false "${DVWA_INITIALIZE_DATABASE}"
    return
  fi
  if [[ "${FRESH_DEPLOYMENT}" == true ]]; then
    prompt_yes_no "Initialize the new DVWA database through Azure Run Command" true
  else
    prompt_yes_no "Reset the existing DVWA database" false
  fi
}

printf '\nPrivate DVWA one-command deployment\n'
printf '===================================\n\n'

install_missing_commands
login_and_select_subscription
prepare_ssh_public_key

configure_if_needed
"${TOOLS_DIR}/00-check-prerequisites.sh"

if [[ "${configure_only}" == true ]]; then
  info "Configuration completed; --configure-only requested, so no Terraform plan was created."
  exit 0
fi

if [[ "${skip_provider_registration}" != true ]]; then
  "${TOOLS_DIR}/01-register-providers.sh"
fi

"${TOOLS_DIR}/03-validate.sh"

FRESH_DEPLOYMENT=true
# grep must consume the complete stream: with pipefail, grep -q can close the
# pipe after the match and turn Terraform's resulting SIGPIPE into a false
# "fresh deployment" result.
if terraform_command state list 2>/dev/null | grep -Fx 'azurerm_managed_disk.data' >/dev/null; then
  FRESH_DEPLOYMENT=false
fi

"${TOOLS_DIR}/04-plan.sh"

if [[ "${plan_only}" == true ]]; then
  info "Plan completed; --plan-only requested, so no Azure workload changes were applied."
  exit 0
fi

if [[ "${assume_yes}" != true ]]; then
  confirm_action \
    "DEPLOY DVWA" \
    "The reviewed plan will be applied, configured consumer peerings reconciled, and the private VM verified."
fi

"${TOOLS_DIR}/05-apply.sh" --yes
reconcile_reciprocal_peerings
"${TOOLS_DIR}/07-verify.sh"

if should_initialize_database; then
  "${TOOLS_DIR}/08-initialize-dvwa.sh" --via-run-command --yes
fi

printf '\nDeployment complete.\n'
printf '  Resource group: %s\n' "${RESOURCE_GROUP_NAME}"
printf '  Private URL:    %s\n' "${PRIVATE_DVWA_URL}"
printf '  Lifecycle:      task deactivate / task activate\n'
printf '  Verification:   task verify\n'
