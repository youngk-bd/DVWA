#!/usr/bin/env bash
# Exercise the host apply gate, especially Azure's exit-zero guest failures.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mkdir "$test_dir/bin"
export APPLY_MARKER="$test_dir/applied"
export ARM_SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000001"
export TF_VAR_admin_ssh_public_key="ssh-ed25519 test-key"
printf 'test plan\n' > "$test_dir/test.tfplan"
printf '%s\n%s\n' "$ARM_SUBSCRIPTION_ID" "$(shasum -a 256 "$test_dir/test.tfplan" | awk '{print $1}')" \
  > "$test_dir/test.tfplan.subscription-id"
cat > "$test_dir/bin/az" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"account show"*"--query name"*) echo BYTEDEFENSE_INFRA_NON_PROD ;;
  *"account show"*"--query id"*) echo "$ARM_SUBSCRIPTION_ID" ;;
  *"account show"*) ;;
  *"get-instance-view"*) echo PowerState/running ;;
  *"run-command invoke"*) echo "$GUEST_RESULT" ;;
  *) exit 9 ;;
esac
MOCK
cat > "$test_dir/bin/terraform" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"show -json"*) printf '{"resource_changes":[{"type":"azurerm_linux_virtual_machine","change":{"actions":["delete","create"]}}]}\n' ;;
  *"apply"*) touch "$APPLY_MARKER" ;;
  *"output"*) ;;
  *) exit 9 ;;
esac
MOCK
chmod +x "$test_dir/bin/"*
export PATH="$test_dir/bin:$PATH"
export GUEST_RESULT="Guest script failed with exit code 1"
if bash "$TOOLS_DIR/05-apply.sh" --plan "$test_dir/test.tfplan" --yes > "$test_dir/log" 2>&1; then
  echo "FAIL: apply accepted a guest failure"; exit 1
fi
[[ ! -e "$APPLY_MARKER" ]]
grep -q 'Storage could not be quiesced' "$test_dir/log"
echo "PASS: Azure exit-zero guest failure blocks Terraform"
export GUEST_RESULT="DVWA_STORAGE_QUIESCED"
bash "$TOOLS_DIR/05-apply.sh" --plan "$test_dir/test.tfplan" --yes > "$test_dir/log" 2>&1
[[ -f "$APPLY_MARKER" ]]
echo "PASS: verified shutdown permits Terraform"
