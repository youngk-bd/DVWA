#!/usr/bin/env bash
# LUN 10 is the retained DVWA managed disk. Never infer a blank disk from a
# failed command, or mount over an existing database on the OS disk.
set -euo pipefail

storage_error() { echo "DVWA storage: $*" >&2; return 1; }

find_data_disk() {
  local candidate attempt
  for attempt in $(seq 1 120); do
    for candidate in /dev/disk/azure/data/by-lun/10 /dev/disk/azure/scsi1/lun10; do
      if [[ -b "$candidate" ]]; then
        readlink -f "$candidate"
        return
      fi
    done
    sleep 5
  done
  storage_error "LUN 10 did not appear; refusing to start DVWA on the OS disk."
}

prepare_filesystem() {
  local device="$1" probe rc=0 signatures device_type mounts children
  device_type="$(lsblk -dnro TYPE "$device")"
  [[ "$device_type" == disk ]] || { storage_error "Expected a whole managed data disk."; return 1; }
  mounts="$(lsblk -nro MOUNTPOINTS "$device")"
  [[ -z "${mounts//[[:space:]]/}" ]] ||
    { storage_error "Disk or a child is mounted; refusing to format it."; return 1; }
  children="$(lsblk -nrpo NAME "$device")"
  [[ "$children" == "$device" ]] ||
    { storage_error "Partitioned disk requires manual inspection; leaving it untouched."; return 1; }

  probe="$(blkid -p -o export "$device")" || rc=$?
  if [[ $rc == 0 ]]; then
    grep -qx 'TYPE=ext4' <<<"$probe" ||
      { storage_error "Existing filesystem is not ext4; leaving it untouched."; return 1; }
  elif [[ $rc == 2 ]]; then
    signatures="$(wipefs --no-act --noheadings --output TYPE "$device")"
    [[ -z "${signatures//[[:space:]]/}" ]] ||
      { storage_error "Unrecognized disk signatures; leaving it untouched."; return 1; }
    mkfs.ext4 -L dvwa-data "$device"
  else
    storage_error "blkid failed ($rc); disk contents are unknown."
    return 1
  fi
}

configure_data_mount() {
  local device="$1" uuid existing
  uuid="$(blkid -s UUID -o value "$device")"
  [[ -n "$uuid" ]] || { storage_error "Missing filesystem UUID."; return 1; }
  existing="$(awk '$1 !~ /^#/ && $2 == "/opt/dvwa" {print $1}' /etc/fstab)"
  if [[ -n "$existing" && "$existing" != "UUID=$uuid" ]]; then
    storage_error "/etc/fstab already maps /opt/dvwa to another source."
    return 1
  fi
  if [[ -z "$existing" ]]; then
    printf 'UUID=%s /opt/dvwa ext4 defaults,nofail 0 2\n' "$uuid" >> /etc/fstab
  fi
  install -d -m 0750 /opt/dvwa
  systemctl daemon-reload
  mountpoint -q /opt/dvwa || mount /opt/dvwa
  [[ "$(findmnt -rn -M /opt/dvwa -o UUID)" == "$uuid" ]] ||
    { storage_error "/opt/dvwa is not mounted from the expected data disk."; return 1; }
}

main() {
  local device uuid
  [[ $EUID == 0 ]] || { storage_error "Must run as root."; return 1; }
  exec 9>/run/lock/dvwa-storage.lock
  flock -n 9 || { storage_error "Another storage operation is running."; return 1; }
  device="$(find_data_disk)"
  if mountpoint -q /opt/dvwa; then
    uuid="$(blkid -s UUID -o value "$device")"
    [[ -n "$uuid" && "$(findmnt -rn -M /opt/dvwa -o UUID)" == "$uuid" ]] ||
      { storage_error "/opt/dvwa is mounted from the wrong disk."; return 1; }
    return
  fi
  if [[ -d /opt/dvwa ]] && [[ -n "$(find /opt/dvwa -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    storage_error "/opt/dvwa contains OS-disk data. Run the explicit migration first."
    return 1
  fi
  prepare_filesystem "$device"
  configure_data_mount "$device"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
