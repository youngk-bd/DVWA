#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: ./tools/01-register-providers.sh

Registers the Azure resource providers used by the DVWA stack and waits until
all of them report Registered. This changes subscription provider state but
does not create workload resources.
EOF
  exit 0
fi

ensure_azure_subscription

providers=(
  Microsoft.Authorization
  Microsoft.Compute
  Microsoft.Insights
  Microsoft.Network
  Microsoft.OperationalInsights
)

for provider_namespace in "${providers[@]}"; do
  info "Requesting registration for ${provider_namespace}."
  az provider register \
    --subscription "${ARM_SUBSCRIPTION_ID}" \
    --namespace "${provider_namespace}" \
    --output none
done

for provider_namespace in "${providers[@]}"; do
  info "Waiting for ${provider_namespace} registration."
  for attempt in $(seq 1 60); do
    registration_state="$(
      az provider show \
        --subscription "${ARM_SUBSCRIPTION_ID}" \
        --namespace "${provider_namespace}" \
        --query registrationState \
        --output tsv
    )"
    if [[ "${registration_state}" == "Registered" ]]; then
      info "${provider_namespace} is Registered."
      break
    fi
    if [[ "${attempt}" == "60" ]]; then
      die "Timed out waiting for ${provider_namespace}; last state was ${registration_state}."
    fi
    sleep 10
  done
done

info "All required providers are registered."
