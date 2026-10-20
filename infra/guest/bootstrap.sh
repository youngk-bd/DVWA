#!/usr/bin/env bash
set -euo pipefail

# One fail-fast cloud-init command: disk failures must stop every later step.
/usr/local/sbin/dvwa-prepare-storage
mountpoint -q /opt/dvwa
install -d -m 0700 /opt/dvwa/mysql
if [[ ! -s /opt/dvwa/.env ]]; then
  # Never regenerate credentials over a retained database.
  [[ -z "$(find /opt/dvwa/mysql -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
    { echo "Retained database has no .env; refusing to replace credentials." >&2; exit 1; }
  umask 077
  printf 'DVWA_DB_PASSWORD=%s\nMARIADB_ROOT_PASSWORD=%s\n' \
    "$(openssl rand -hex 24)" "$(openssl rand -hex 24)" > /opt/dvwa/.env
fi
chmod 600 /opt/dvwa/.env
# Azure extensions can install packages concurrently with cloud-init.
DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y curl docker.io docker-compose-v2 openssl rsyslog
systemctl daemon-reload
systemctl enable --now rsyslog docker
docker compose --env-file /opt/dvwa/.env --file /usr/local/share/dvwa/compose.yaml pull
systemctl enable --now dvwa.service dvwa-proxy.socket
/usr/local/sbin/dvwa-verify
