#!/usr/bin/env bash

# Shared, source-only helpers for the DVWA Azure deployment tools.

set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$(cd "${TOOLS_DIR}/.." && pwd)"

EXPECTED_SUBSCRIPTION_NAME="BYTEDEFENSE_INFRA_NON_PROD"
RESOURCE_GROUP_NAME="rg-test-server-dvwa"
VM_NAME="vm-test-server-dvwa"
VNET_NAME="vnet-test-server-dvwa"
PRIVATE_DVWA_URL="http://dvwa.dvwa.internal"

info() {
  printf 'INFO: %s\n' "$*"
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  command -v "${command_name}" >/dev/null 2>&1 || die "Required command not found: ${command_name}"
}

require_environment_variable() {
  local variable_name="$1"
  [[ -n "${!variable_name:-}" ]] || die "Required environment variable is not set: ${variable_name}"
}

ensure_azure_subscription() {
  local selected_subscription_id
  local selected_subscription_name

  require_command az
  az account show >/dev/null 2>&1 || die "Azure CLI is not authenticated. Run 'az login' first."

  if [[ -n "${ARM_SUBSCRIPTION_ID:-}" ]]; then
    selected_subscription_id="${ARM_SUBSCRIPTION_ID}"
  else
    selected_subscription_id="$(az account show --query id --output tsv)"
  fi

  selected_subscription_name="$(
    az account show \
      --subscription "${selected_subscription_id}" \
      --query name \
      --output tsv
  )"

  [[ "${selected_subscription_name}" == "${EXPECTED_SUBSCRIPTION_NAME}" ]] ||
    die "Selected subscription is '${selected_subscription_name}', expected '${EXPECTED_SUBSCRIPTION_NAME}'."

  ARM_SUBSCRIPTION_ID="$(
    az account show \
      --subscription "${selected_subscription_id}" \
      --query id \
      --output tsv
  )"
  export ARM_SUBSCRIPTION_ID

  info "Validated subscription ${EXPECTED_SUBSCRIPTION_NAME} (${ARM_SUBSCRIPTION_ID})."
}

load_ssh_public_key() {
  local public_key

  if [[ -n "${TF_VAR_admin_ssh_public_key:-}" ]]; then
    public_key="${TF_VAR_admin_ssh_public_key}"
  elif [[ -n "${DVWA_SSH_PUBLIC_KEY_FILE:-}" ]]; then
    [[ -f "${DVWA_SSH_PUBLIC_KEY_FILE}" ]] ||
      die "DVWA_SSH_PUBLIC_KEY_FILE does not exist: ${DVWA_SSH_PUBLIC_KEY_FILE}"
    IFS= read -r public_key <"${DVWA_SSH_PUBLIC_KEY_FILE}"
    TF_VAR_admin_ssh_public_key="${public_key}"
    export TF_VAR_admin_ssh_public_key
  else
    die "Set TF_VAR_admin_ssh_public_key or DVWA_SSH_PUBLIC_KEY_FILE before running Terraform."
  fi

  case "${public_key}" in
    ssh-ed25519\ * | ssh-rsa\ * | ecdsa-sha2-nistp256\ * | ecdsa-sha2-nistp384\ * | ecdsa-sha2-nistp521\ *) ;;
    *) die "The configured SSH public key is not in a supported OpenSSH format." ;;
  esac
}

terraform_command() {
  require_command terraform
  terraform -chdir="${INFRA_DIR}" "$@"
}

plan_subscription_file() {
  printf '%s.subscription-id' "$1"
}

file_sha256() {
  local file_path="$1"

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file_path}" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file_path}" | awk '{print $1}'
  else
    die "Neither shasum nor sha256sum is available to bind the saved plan."
  fi
}

bind_plan_to_subscription() {
  local plan_file="$1"
  local binding_file
  local plan_digest

  binding_file="$(plan_subscription_file "${plan_file}")"
  plan_digest="$(file_sha256 "${plan_file}")"
  printf '%s\n%s\n' "${ARM_SUBSCRIPTION_ID}" "${plan_digest}" >"${binding_file}"
  chmod 600 "${binding_file}"
}

verify_plan_subscription() {
  local plan_file="$1"
  local binding_file
  local current_plan_digest
  local planned_plan_digest
  local planned_subscription_id

  binding_file="$(plan_subscription_file "${plan_file}")"
  [[ -f "${binding_file}" ]] ||
    die "Plan binding file is missing: ${binding_file}. Recreate the plan with the matching planning tool."

  planned_subscription_id="$(sed -n '1p' "${binding_file}")"
  planned_plan_digest="$(sed -n '2p' "${binding_file}")"
  [[ "${planned_subscription_id}" == "${ARM_SUBSCRIPTION_ID}" ]] ||
    die "Plan was created for subscription ${planned_subscription_id}, not ${ARM_SUBSCRIPTION_ID}."

  [[ -n "${planned_plan_digest}" ]] || die "Plan binding has no SHA-256 digest. Recreate the plan."
  current_plan_digest="$(file_sha256 "${plan_file}")"
  [[ "${current_plan_digest}" == "${planned_plan_digest}" ]] ||
    die "Saved plan content changed after subscription binding. Recreate and review the plan."
}

confirm_action() {
  local phrase="$1"
  local prompt="$2"
  local response

  [[ -t 0 ]] || die "Interactive confirmation requires a terminal. Re-run with --yes only after reviewing the action."
  printf '%s\n' "${prompt}" >&2
  printf 'Type %s to continue: ' "${phrase}" >&2
  IFS= read -r response
  [[ "${response}" == "${phrase}" ]] || die "Confirmation did not match; no changes were made."
}

show_common_environment_help() {
  cat <<'EOF'
Required environment:
  ARM_SUBSCRIPTION_ID          BYTEDEFENSE_INFRA_NON_PROD subscription UUID.
  TF_VAR_admin_ssh_public_key  Full OpenSSH public key value.

Instead of TF_VAR_admin_ssh_public_key, set:
  DVWA_SSH_PUBLIC_KEY_FILE     Path to an OpenSSH .pub file.

Azure CLI must already be authenticated with `az login` or an equivalent
service-principal/workload-identity login. Secrets remain in environment
variables and are never written by these tools.
EOF
}
