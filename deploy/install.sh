#!/usr/bin/env bash
# Installs Quickly (self-hosted cold-email tool) on this Ubuntu VPS.
#
# Safety rules this script follows:
#   - Never touches Docker/containers/networks/volumes that don't start
#     with "quickly" — other apps on this box are left alone.
#   - Never installs Docker if it's already present.
#   - Never binds port 80/443 unless you explicitly choose the "bare VPS"
#     path AND nothing is already listening on them.
#   - Idempotent: safe to re-run.
set -euo pipefail

INSTALL_DIR="/opt/quickly"
COMPOSE_PROJECT="quickly"

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run this with sudo: sudo bash install.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
log "Checking Docker"
if ! command -v docker >/dev/null 2>&1; then
  log "Docker not found — installing via Docker's official apt repo (not touching any existing package sources for other apps)"
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
  log "Docker already installed — leaving it as-is"
fi
docker compose version >/dev/null 2>&1 \
  || die "docker compose plugin missing; install docker-compose-plugin manually and re-run"

# ---------------------------------------------------------------------------
log "Setting up ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/backups"
cp "${SCRIPT_DIR}/docker-compose.no-caddy.yml" "${SCRIPT_DIR}/docker-compose.caddy.yml" \
   "${SCRIPT_DIR}/Caddyfile" "${INSTALL_DIR}/"
[ -f "${INSTALL_DIR}/.env" ] || cp "${SCRIPT_DIR}/.env.example" "${INSTALL_DIR}/.env"

# ---------------------------------------------------------------------------
log "Checking whether ports 80/443 are already in use by another app"
PORTS_BUSY=0
if ss -ltn 2>/dev/null | grep -qE ':(80|443)\s'; then
  PORTS_BUSY=1
fi

if [ "$PORTS_BUSY" -eq 1 ]; then
  echo "Ports 80/443 are already bound on this VPS (likely your existing nginx/Caddy)."
  echo "Using docker-compose.no-caddy.yml — Quickly will only bind 127.0.0.1:8000."
  echo "You'll point your existing reverse proxy at it (see deploy/nginx-quickly.conf.example)."
  COMPOSE_FILE="docker-compose.no-caddy.yml"
else
  read -rp "No web server detected on 80/443. Do you want Quickly to manage HTTPS itself via Caddy? [Y/n] " ans
  if [[ "${ans:-Y}" =~ ^[Nn] ]]; then
    COMPOSE_FILE="docker-compose.no-caddy.yml"
  else
    COMPOSE_FILE="docker-compose.caddy.yml"
    read -rp "Enter the domain that points to this VPS (e.g. mail.yourdomain.com): " DOMAIN
    [ -n "${DOMAIN:-}" ] || die "A domain is required for automatic HTTPS."
    sed -i "s#^CADDY_HOST=.*#CADDY_HOST=${DOMAIN}#" "${INSTALL_DIR}/.env"
    sed -i "s#^BASE_URL=.*#BASE_URL=https://${DOMAIN}#" "${INSTALL_DIR}/.env"
    sed -i "s#^CORS_ORIGINS=.*#CORS_ORIGINS=https://${DOMAIN}#" "${INSTALL_DIR}/.env"
  fi
fi

# ---------------------------------------------------------------------------
if grep -q '^QUICKLY_SECRET_KEY=$' "${INSTALL_DIR}/.env" 2>/dev/null; then
  log "Generating QUICKLY_SECRET_KEY"
  SECRET="$(openssl rand -hex 32)"
  sed -i "s#^QUICKLY_SECRET_KEY=.*#QUICKLY_SECRET_KEY=${SECRET}#" "${INSTALL_DIR}/.env"
fi

# ---------------------------------------------------------------------------
log "Creating dedicated Docker volume (isolated from any other app's data)"
docker volume inspect quickly_pgdata >/dev/null 2>&1 || docker volume create quickly_pgdata >/dev/null

# ---------------------------------------------------------------------------
log "Starting Quickly (project name: ${COMPOSE_PROJECT}) using ${COMPOSE_FILE}"
cd "${INSTALL_DIR}"
docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" up -d

log "Done."
echo
if [ "$COMPOSE_FILE" = "docker-compose.no-caddy.yml" ]; then
  echo "Quickly is running on 127.0.0.1:8000 (this VPS only, not the public internet yet)."
  echo "Next: point your existing reverse proxy at it. A sample nginx vhost is in"
  echo "  ${SCRIPT_DIR}/nginx-quickly.conf.example"
  echo "Then set BASE_URL and CORS_ORIGINS in ${INSTALL_DIR}/.env to your real https:// domain and run:"
  echo "  cd ${INSTALL_DIR} && docker compose -p quickly -f ${COMPOSE_FILE} up -d"
else
  echo "Quickly is starting up behind its own Caddy instance."
  echo "Once DNS for your domain points at this VPS, open: https://<your-domain>"
  echo "(Let's Encrypt certificate issuance may take a minute on first request.)"
fi
echo
echo "Manage it any time from ${INSTALL_DIR}:"
echo "  docker compose -p quickly -f ${COMPOSE_FILE} logs -f       # view logs"
echo "  docker compose -p quickly -f ${COMPOSE_FILE} down          # stop"
echo "  docker compose -p quickly -f ${COMPOSE_FILE} up -d         # start again"
