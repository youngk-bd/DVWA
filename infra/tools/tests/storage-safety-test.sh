#!/usr/bin/env bash
# Run the real filesystem decision logic with fake block-device tools.
# No disk, mount, root permissions, or Azure access is needed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export STORAGE_SCRIPT="${SCRIPT_DIR}/../../guest/prepare-storage.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
export FORMAT_MARKER="$test_dir/formatted"

run_case() {
  local scenario="$1" expected="$2" expected_format="$3" rc=0
  rm -f "$FORMAT_MARKER"
  CASE="$scenario" bash <<'BASH' >/dev/null 2>&1 || rc=$?
source "$STORAGE_SCRIPT"
lsblk() {
  case "$1" in
    -dnro) echo disk ;;
    -nro) [[ "$CASE" != mounted ]] || echo / ;;
    -nrpo)
      echo /dev/test-data
      [[ "$CASE" != partitioned ]] || echo /dev/test-data1
      ;;
  esac
}
blkid() {
  case "$CASE" in
    blank|signature) return 2 ;;
    probe_error) return 4 ;;
    wrong_fs) echo TYPE=xfs ;;
    *) echo TYPE=ext4 ;;
  esac
}
wipefs() {
  [[ "$CASE" != signature ]] || echo gpt
}
mkfs.ext4() { touch "$FORMAT_MARKER"; }
prepare_filesystem /dev/test-data
BASH
  if [[ "$expected" == pass ]]; then
    [[ $rc == 0 ]] || { echo "FAIL: $scenario unexpectedly failed"; exit 1; }
  else
    [[ $rc != 0 ]] || { echo "FAIL: $scenario unexpectedly passed"; exit 1; }
  fi
  if [[ "$expected_format" == yes ]]; then
    [[ -f "$FORMAT_MARKER" ]]
  else
    [[ ! -e "$FORMAT_MARKER" ]] || { echo "FAIL: $scenario formatted a protected disk"; exit 1; }
  fi
  echo "PASS: $scenario"
}

run_case blank pass yes
run_case retained_ext4 pass no
run_case mounted fail no
run_case partitioned fail no
run_case wrong_fs fail no
run_case signature fail no
run_case probe_error fail no
