#!/usr/bin/env bash
# One-time migration of a legacy OS-disk database to the retained LUN 10 disk.
# Install prepare-storage.sh as /usr/local/sbin/dvwa-prepare-storage first.
set -euo pipefail
umask 077
source /usr/local/sbin/dvwa-prepare-storage
[[ $EUID == 0 ]]
exec 9>/run/lock/dvwa-storage.lock
flock -n 9

device="$(find_data_disk)"
if mountpoint -q /opt/dvwa; then
  configure_data_mount "$device"
  echo "Data disk is already mounted; no migration performed."
  exit 0
fi
[[ -s /opt/dvwa/.env && -d /opt/dvwa/mysql/mysql ]] ||
  { storage_error "Expected existing credentials and MariaDB system database."; exit 1; }
command -v rsync >/dev/null
prepare_filesystem "$device"
stage="$(mktemp -d /mnt/dvwa-migration.XXXXXX)"
mount "$device" "$stage"
trap 'mountpoint -q "$stage" && umount "$stage"; rmdir "$stage" 2>/dev/null || true' EXIT
[[ -z "$(find "$stage" -mindepth 1 -maxdepth 1 ! -name lost+found -print -quit)" ]] ||
  { storage_error "Data disk is not empty; refusing to overwrite it."; exit 1; }

compose=(docker compose --env-file /opt/dvwa/.env --file /usr/local/share/dvwa/compose.yaml)
backup="/opt/dvwa.os-backup.$(date -u +%Y%m%dT%H%M%SZ)"
[[ ! -e "$backup" ]]

# Keep a logical backup as well as the cleanly stopped database files.
install -d -m 0700 /opt/dvwa/recovery
"${compose[@]}" exec -T db sh -c \
  'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mariadb-dump -uroot --single-transaction --routines --events --databases dvwa' \
  > /opt/dvwa/recovery/dvwa-before-storage-migration.sql
[[ -s /opt/dvwa/recovery/dvwa-before-storage-migration.sql ]]
echo "Database dump saved locally; stopping DVWA for the data copy."
systemctl stop dvwa-proxy.socket dvwa-proxy.service
systemctl stop dvwa
"${compose[@]}" down
systemctl stop docker.service docker.socket
rsync -aHAX --numeric-ids /opt/dvwa/ "$stage/"
[[ -z "$(rsync -aHAXnci --numeric-ids /opt/dvwa/ "$stage/")" ]] ||
  { storage_error "Copied data did not verify; services remain stopped and source is retained."; exit 1; }
sync
umount "$stage"
mv /opt/dvwa "$backup"
install -d -m 0750 /opt/dvwa
configure_data_mount "$device"

# Docker restart policies otherwise bypass the DVWA unit's mount dependency.
for unit in docker dvwa; do
  install -d -m 0755 "/etc/systemd/system/$unit.service.d"
  cat > "/etc/systemd/system/$unit.service.d/dvwa-storage.conf" <<'UNIT'
[Unit]
RequiresMountsFor=/opt/dvwa

[Service]
ExecStartPre=/usr/bin/mountpoint -q /opt/dvwa
UNIT
done
systemctl daemon-reload
systemctl start docker
systemctl start dvwa dvwa-proxy.socket
/usr/local/sbin/dvwa-verify
echo "Original database files retained at $backup"
echo DVWA_STORAGE_MIGRATED
