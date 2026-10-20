#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assume_yes=false
dvwa_url="${DVWA_URL:-${PRIVATE_DVWA_URL}}"
via_run_command=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      [[ $# -ge 2 ]] || die "--url requires a URL."
      dvwa_url="$2"
      shift 2
      ;;
    --yes)
      assume_yes=true
      shift
      ;;
    --via-run-command)
      via_run_command=true
      shift
      ;;
    --help)
      cat <<EOF
Usage: ./tools/08-initialize-dvwa.sh [--url URL] [--via-run-command] [--yes]

Fetches the DVWA setup CSRF token and submits Create / Reset Database. This
DROPS and recreates the DVWA database, including default admin credentials.
Run it only from an approved client with private access to the endpoint.

--via-run-command performs the HTTP operation from inside the Azure VM through
the Azure control plane, so the operator does not need direct private routing.

Default URL: ${PRIVATE_DVWA_URL}
Without --yes, the script requires the phrase RESET DVWA DATABASE.
EOF
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_command curl

if [[ "${assume_yes}" != true ]]; then
  confirm_action \
    "RESET DVWA DATABASE" \
    "This will drop and recreate the DVWA database at ${dvwa_url}."
fi

if [[ "${via_run_command}" == true ]]; then
  ensure_azure_subscription

  remote_script="$(cat <<'REMOTE_SCRIPT'
set -eu
dvwa_url="http://127.0.0.1"
temporary_directory="$(mktemp -d)"
cookie_file="${temporary_directory}/cookies.txt"
setup_page="${temporary_directory}/setup.html"
result_page="${temporary_directory}/result.html"
cleanup() {
  rm -f -- "${cookie_file}" "${setup_page}" "${result_page}"
  rmdir "${temporary_directory}" 2>/dev/null || true
}
trap cleanup EXIT
curl --fail --show-error --silent --connect-timeout 10 --max-time 60 --cookie-jar "${cookie_file}" "${dvwa_url}/setup.php" --output "${setup_page}"
csrf_token="$(sed -n "s/.*name='user_token' value='\([^']*\)'.*/\1/p" "${setup_page}" | sed -n '1p')"
test -n "${csrf_token}" || { echo "Could not extract setup CSRF token" >&2; exit 1; }
curl --fail --show-error --silent --location --connect-timeout 10 --max-time 120 --cookie "${cookie_file}" --cookie-jar "${cookie_file}" --data-urlencode 'create_db=Create / Reset Database' --data-urlencode "user_token=${csrf_token}" "${dvwa_url}/setup.php" --output "${result_page}"
grep -q 'Setup successful' "${result_page}" || { echo "DVWA did not report successful setup" >&2; exit 1; }
echo DVWA_DATABASE_INITIALIZED
REMOTE_SCRIPT
)"

  run_command_output="$(
    az vm run-command invoke \
      --subscription "${ARM_SUBSCRIPTION_ID}" \
      --resource-group "${RESOURCE_GROUP_NAME}" \
      --name "${VM_NAME}" \
      --command-id RunShellScript \
      --scripts "${remote_script}" \
      --query 'value[].message' \
      --output tsv
  )"

  printf '%s\n' "${run_command_output}"
  grep -q 'DVWA_DATABASE_INITIALIZED' <<<"${run_command_output}" ||
    die "Remote DVWA database initialization did not return its success marker."

  info "DVWA database initialization succeeded through Azure Run Command."
  info "Login URL: ${dvwa_url%/}/login.php"
  info "Default credentials are admin / password; use them only inside the isolated test environment."
  exit 0
fi

temporary_directory="$(mktemp -d)"
cookie_file="${temporary_directory}/cookies.txt"
setup_page="${temporary_directory}/setup.html"
result_page="${temporary_directory}/result.html"

cleanup() {
  rm -f -- "${cookie_file}" "${setup_page}" "${result_page}"
  rmdir "${temporary_directory}" 2>/dev/null || true
}
trap cleanup EXIT

curl \
  --fail \
  --show-error \
  --silent \
  --connect-timeout 10 \
  --max-time 60 \
  --cookie-jar "${cookie_file}" \
  "${dvwa_url%/}/setup.php" \
  --output "${setup_page}"

csrf_token="$(
  sed -n "s/.*name='user_token' value='\([^']*\)'.*/\1/p" "${setup_page}" | sed -n '1p'
)"

[[ -n "${csrf_token}" ]] || die "Could not extract the DVWA setup CSRF token. Check endpoint reachability and page content."

curl \
  --fail \
  --show-error \
  --silent \
  --location \
  --connect-timeout 10 \
  --max-time 120 \
  --cookie "${cookie_file}" \
  --cookie-jar "${cookie_file}" \
  --data-urlencode 'create_db=Create / Reset Database' \
  --data-urlencode "user_token=${csrf_token}" \
  "${dvwa_url%/}/setup.php" \
  --output "${result_page}"

if ! grep -q 'Setup successful' "${result_page}"; then
  die "DVWA did not report successful setup. Inspect the setup page and container logs."
fi

info "DVWA database initialization succeeded."
info "Login URL: ${dvwa_url%/}/login.php"
info "Default credentials are admin / password; use them only inside the isolated test environment."
