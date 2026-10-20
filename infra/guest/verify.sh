#!/usr/bin/env bash
set -euo pipefail

mountpoint -q /opt/dvwa
device=""
for candidate in /dev/disk/azure/data/by-lun/10 /dev/disk/azure/scsi1/lun10; do
  if [[ -b "$candidate" ]]; then device="$(readlink -f "$candidate")"; break; fi
done
[[ -n "$device" ]]
uuid="$(blkid -s UUID -o value "$device")"
[[ -n "$uuid" && "$(findmnt -rn -M /opt/dvwa -o UUID)" == "$uuid" ]]
echo DVWA_DATA_DISK_OK
systemctl is-active docker dvwa dvwa-proxy.socket
compose=(docker compose --env-file /opt/dvwa/.env --file /usr/local/share/dvwa/compose.yaml)
db_id="$("${compose[@]}" ps -q db)"
[[ -n "$db_id" ]]
healthy=false
for attempt in $(seq 1 60); do
  if [[ "$(docker inspect --format '{{.State.Health.Status}}' "$db_id")" == healthy ]]; then
    healthy=true
    break
  fi
  sleep 2
done
[[ "$healthy" == true ]]
echo DVWA_DATABASE_HEALTHY
"${compose[@]}" ps
for attempt in $(seq 1 30); do
  # Consume the full response to avoid curl SIGPIPE under pipefail.
  if curl --fail --show-error --silent --max-time 10 http://127.0.0.1/login.php |
    grep -F 'Damn Vulnerable Web Application' >/dev/null; then
    printf 'DEFAULT_SECURITY_LEVEL='
    "${compose[@]}" exec -T dvwa printenv DEFAULT_SECURITY_LEVEL
    echo DVWA_HTTP_OK
    echo DVWA_VERIFY_OK
    exit 0
  fi
  sleep 2
done
echo "DVWA login did not become ready." >&2
exit 1
