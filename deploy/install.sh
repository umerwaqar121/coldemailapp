#!/usr/bin/env bash
# Installs Quickly (self-hosted cold-email tool) on this Ubuntu VPS,
# alongside already-running services this script must not disturb:
#   aether-job-poller.service, aether-send-server.service, voice-agent.service,
#   nginx, docker, containerd.
#
# Safety rules this script follows — read before running:
#   - Never installs or restarts Docker/containerd. If `docker` isn't found
#     it aborts instead of installing anything (this host is expected to
#     already have it).
#   - Never touches /etc/nginx/nginx.conf or the default site. It only ever
#     writes ONE new file, /etc/nginx/sites-available/quickly.conf, and only
#     when you pass a domain via QUICKLY_DOMAIN. `nginx -t` must pass before
#     the symlink is kept; if it fails, the symlink is removed and nginx is
#     left completely untouched (no reload is issued).
#   - Reloads nginx (`systemctl reload`), never restarts it — existing
#     connections to your other sites are not dropped.
#   - Auto-picks a free loopback port for Quickly (checks 8000-8010) instead
#     of assuming 8000 is free, so it can't collide with
#     aether-send-server/voice-agent/anything else already bound.
#   - Everything Quickly owns is isolated: its own Docker Compose project
#     ("quickly"), its own named volume ("quickly_pgdata"), its own
#     directory (/opt/quickly). Nothing outside that is created, modified,
#     or deleted.
#   - No reboots. No `systemctl disable`/`stop` on anything. No `rm -rf`
#     outside /opt/quickly. Safe to re-run (idempotent).
#   - Non-interactive: no prompts. Configure via env vars (see below).
#
# Usage:
#   sudo QUICKLY_DOMAIN=mail.yourdomain.com bash install.sh
#   sudo bash install.sh                       # skip nginx wiring for now
#
# Env vars:
#   QUICKLY_DOMAIN   Optional. If set, adds an nginx server block for this
#                    hostname proxying to Quickly, and sets BASE_URL. DNS
#                    for this hostname must already point at this VPS, or
#                    just leave it unset and wire the reverse proxy later
#                    using deploy/nginx-quickly.conf.example as a template.

set -euo pipefail

INSTALL_DIR="/opt/quickly"
COMPOSE_PROJECT="quickly"
COMPOSE_FILE="docker-compose.no-caddy.yml"
NGINX_SITE="/etc/nginx/sites-available/quickly.conf"
NGINX_LINK="/etc/nginx/sites-enabled/quickly.conf"
WATCH_SERVICES=(aether-job-poller.service aether-send-server.service voice-agent.service nginx)

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\n\033[1;33mWARN:\033[0m %s\n' "$1"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run this with sudo: sudo bash install.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
log "Recording current state of services this script must not disturb"
declare -A BEFORE_STATE
for svc in "${WATCH_SERVICES[@]}"; do
  BEFORE_STATE[$svc]="$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
  echo "  $svc: ${BEFORE_STATE[$svc]}"
done

# ---------------------------------------------------------------------------
log "Checking Docker (will NOT install or restart it)"
command -v docker >/dev/null 2>&1 || die "docker not found. This script refuses to install/modify Docker on a host with other containerized services already running on it — install docker-ce yourself first, or tell me and I'll write a separate, reviewed step for that."
docker compose version >/dev/null 2>&1 || die "docker compose plugin not found. Install docker-compose-plugin yourself, then re-run."
log "Docker present — not touching its installation or service state."
echo "  host architecture: $(dpkg --print-architecture) (Quickly v2.4.0 publishes both linux/amd64 and linux/arm64, so this is fine)"

# ---------------------------------------------------------------------------
log "Picking a free loopback port for Quickly (checking 8000-8010, skipping anything already bound)"
APP_PORT=""
for p in $(seq 8000 8010); do
  if ! ss -ltn 2>/dev/null | grep -qE ":${p}[[:space:]]"; then
    APP_PORT="$p"
    break
  fi
done
[ -n "$APP_PORT" ] || die "No free port found in 8000-8010 — check 'ss -ltnp' manually and free one, or edit this script's range."
echo "  using 127.0.0.1:${APP_PORT}"

# ---------------------------------------------------------------------------
log "Setting up ${INSTALL_DIR} (new, isolated directory — nothing outside it is touched)"
mkdir -p "${INSTALL_DIR}/backups"
cp "${SCRIPT_DIR}/docker-compose.no-caddy.yml" "${INSTALL_DIR}/"
[ -f "${INSTALL_DIR}/.env" ] || cp "${SCRIPT_DIR}/.env.example" "${INSTALL_DIR}/.env"

if grep -q '^QUICKLY_HOST_PORT=' "${INSTALL_DIR}/.env" 2>/dev/null; then
  sed -i "s#^QUICKLY_HOST_PORT=.*#QUICKLY_HOST_PORT=${APP_PORT}#" "${INSTALL_DIR}/.env"
else
  echo "QUICKLY_HOST_PORT=${APP_PORT}" >> "${INSTALL_DIR}/.env"
fi

if grep -q '^QUICKLY_SECRET_KEY=$' "${INSTALL_DIR}/.env" 2>/dev/null; then
  log "Generating QUICKLY_SECRET_KEY"
  SECRET="$(openssl rand -hex 32)"
  sed -i "s#^QUICKLY_SECRET_KEY=.*#QUICKLY_SECRET_KEY=${SECRET}#" "${INSTALL_DIR}/.env"
fi

if [ -n "${QUICKLY_DOMAIN:-}" ]; then
  sed -i "s#^BASE_URL=.*#BASE_URL=https://${QUICKLY_DOMAIN}#" "${INSTALL_DIR}/.env"
  sed -i "s#^CORS_ORIGINS=.*#CORS_ORIGINS=https://${QUICKLY_DOMAIN}#" "${INSTALL_DIR}/.env"
fi

# ---------------------------------------------------------------------------
log "Creating dedicated Docker volume (isolated from any other app's data)"
docker volume inspect quickly_pgdata >/dev/null 2>&1 || docker volume create quickly_pgdata >/dev/null

# ---------------------------------------------------------------------------
log "Starting Quickly (Compose project '${COMPOSE_PROJECT}') — does not touch the Docker daemon itself, only adds containers under this project"
cd "${INSTALL_DIR}"
docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" up -d

# ---------------------------------------------------------------------------
if [ -n "${QUICKLY_DOMAIN:-}" ]; then
  log "Wiring nginx: adding ONE new file (${NGINX_SITE}), no existing config touched"
  command -v nginx >/dev/null 2>&1 || die "nginx not found, but QUICKLY_DOMAIN was set. Aborting without changing anything."

  cat > "${NGINX_SITE}" <<EOF
# Managed by deploy/install.sh for Quickly. Safe to remove this file and
# its symlink in sites-enabled to fully undo — no other nginx config is
# touched by it.
server {
    listen 80;
    server_name ${QUICKLY_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  ln -sf "${NGINX_SITE}" "${NGINX_LINK}"

  if nginx -t 2>/tmp/quickly_nginx_test.log; then
    systemctl reload nginx
    log "nginx reloaded with the new site. Run certbot yourself the same way you did for your other sites, e.g.: sudo certbot --nginx -d ${QUICKLY_DOMAIN}"
  else
    warn "nginx config test FAILED — rolling back, your existing sites are untouched:"
    cat /tmp/quickly_nginx_test.log >&2
    rm -f "${NGINX_LINK}"
    die "nginx was NOT reloaded. Quickly is still running on 127.0.0.1:${APP_PORT}; fix the config manually and re-run."
  fi
else
  log "QUICKLY_DOMAIN not set — leaving nginx untouched."
  echo "Quickly is reachable only at 127.0.0.1:${APP_PORT} on this box for now."
  echo "A ready-to-adapt vhost is at: ${SCRIPT_DIR}/nginx-quickly.conf.example"
  echo "Re-run as: sudo QUICKLY_DOMAIN=mail.yourdomain.com bash install.sh"
fi

# ---------------------------------------------------------------------------
log "Verifying the services this script promised not to disturb are still in their original state"
DRIFT=0
for svc in "${WATCH_SERVICES[@]}"; do
  after="$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
  if [ "$after" != "${BEFORE_STATE[$svc]}" ]; then
    warn "$svc changed state: ${BEFORE_STATE[$svc]} -> ${after}"
    DRIFT=1
  else
    echo "  $svc: still ${after}"
  fi
done
[ "$DRIFT" -eq 0 ] || warn "Investigate the drift above — this script did not intentionally touch any of those services."

log "Done."
echo
echo "Manage it any time from ${INSTALL_DIR}:"
echo "  docker compose -p quickly -f ${COMPOSE_FILE} logs -f       # view logs"
echo "  docker compose -p quickly -f ${COMPOSE_FILE} down          # stop"
echo "  docker compose -p quickly -f ${COMPOSE_FILE} up -d         # start again"
