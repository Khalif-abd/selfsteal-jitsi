#!/usr/bin/env bash
set -Eeuo pipefail

# selfsteal-jitsi.sh v3
# Jitsi Meet behind Remnawave/Xray Reality -> nginx-selfsteal -> 127.0.0.1:8000
#
# Public:
#   TCP/443   -> Xray Reality -> nginx-selfsteal -> Jitsi HTTP
#   UDP/10000 -> Jitsi Videobridge
#
# Jitsi web itself is NOT published on 443/8443.

VERSION="3.0.1"
REPO="${SELFSTEAL_JITSI_REPO:-khalif-abd/selfsteal-jitsi}"
BRANCH="${SELFSTEAL_JITSI_BRANCH:-main}"
RAW_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/selfsteal-jitsi.sh"
INSTALL_PATH="${SELFSTEAL_JITSI_INSTALL_PATH:-/usr/local/bin/selfsteal-jitsi}"

SELFSTEAL_DIR="${SELFSTEAL_DIR:-/opt/nginx-selfsteal}"
SELFSTEAL_CONF="${SELFSTEAL_CONF:-$SELFSTEAL_DIR/conf.d/selfsteal.conf}"
JITSI_DIR="${JITSI_DIR:-/opt/jitsi}"
JITSI_CFG="${JITSI_CFG:-/root/.jitsi-meet-cfg}"
STATE_DIR="/etc/selfsteal-jitsi"
STATE_FILE="$STATE_DIR/state.env"
HTTP_PORT="${HTTP_PORT:-8000}"
JVB_PORT="${JVB_PORT:-10000}"
OVERRIDE_FILE="docker-compose.selfsteal.yml"

DOMAIN=""
PUBLIC_IP=""
AUTH="0"
CLEAN="0"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
cat <<EOF
selfsteal-jitsi.sh v${VERSION}

Usage:
  $0 setup
  $0 install [--domain DOMAIN] [--ip IPv4] [--auth|--no-auth] [--clean] [--http-port PORT] [--jvb-port PORT]
  $0 repair
  $0 status
  $0 logs [web|prosody|jicofo|jvb]
  $0 update
  $0 update-script
  $0 version
  $0 uninstall

Examples:
  $0 install --domain meet.example.com --ip 203.0.113.10 --clean
  $0 install --domain meet.example.com --auth --clean
  $0 setup
  $0 repair
  $0 status

--http-port / --jvb-port:
  Override local Jitsi HTTP and public JVB UDP ports.

--clean:
  Stops the current Jitsi stack and recreates Jitsi generated configuration.
  It does NOT remove or reinstall Remnawave/Xray/nginx-selfsteal.
EOF
}

need_root() { [[ $EUID -eq 0 ]] || die "Run as root."; }

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

setup_cmd() {
  have curl || die "curl is required."
  local tmp
  tmp="$(mktemp)"
  log "Installing selfsteal-jitsi to $INSTALL_PATH ..."
  curl -fsSL "$RAW_URL" -o "$tmp" || { rm -f "$tmp"; die "Failed to download $RAW_URL"; }
  bash -n "$tmp" || { rm -f "$tmp"; die "Downloaded script failed bash syntax check."; }
  install -m 0755 "$tmp" "$INSTALL_PATH"
  rm -f "$tmp"
  log "Installed: $INSTALL_PATH"
  log "Run: sudo selfsteal-jitsi --help"
}

update_script_cmd() {
  [[ -e "$INSTALL_PATH" ]] || die "$INSTALL_PATH is not installed. Run setup first."
  setup_cmd
  log "CLI updated from ${REPO}@${BRANCH}."
}

version_cmd() {
  printf 'selfsteal-jitsi %s\n' "$VERSION"
  printf 'Repository: https://github.com/%s\n' "$REPO"
}

have() { command -v "$1" >/dev/null 2>&1; }

compose() {
  cd "$JITSI_DIR"
  docker compose -f docker-compose.yml -f "$OVERRIDE_FILE" "$@"
}

set_env() {
  local key="$1" val="$2" file="$JITSI_DIR/.env"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

detect_domain() {
  [[ -n "$DOMAIN" ]] && return
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE" || true
    DOMAIN="${DOMAIN:-}"
  fi
  if [[ -z "$DOMAIN" && -f "$SELFSTEAL_CONF" ]]; then
    DOMAIN="$(awk '
      /^[[:space:]]*server_name[[:space:]]+/ {
        for (i=2;i<=NF;i++) {
          gsub(/;/,"",$i)
          if ($i !~ /^_/ && $i !~ /^\$/) { print $i; exit }
        }
      }' "$SELFSTEAL_CONF" 2>/dev/null || true)"
  fi
}

detect_ip() {
  [[ -n "$PUBLIC_IP" ]] && return
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE" || true
    PUBLIC_IP="${PUBLIC_IP:-}"
  fi
  if [[ -z "$PUBLIC_IP" ]]; then
    for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
      PUBLIC_IP="$(curl -4fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
      [[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
      PUBLIC_IP=""
    done
  fi
}

save_state() {
  install -d -m 700 "$STATE_DIR"
  cat > "$STATE_FILE" <<EOF
DOMAIN='$DOMAIN'
PUBLIC_IP='$PUBLIC_IP'
AUTH='$AUTH'
HTTP_PORT='$HTTP_PORT'
JVB_PORT='$JVB_PORT'
EOF
  chmod 600 "$STATE_FILE"
}

check_prereqs() {
  have docker || die "Docker is not installed."
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is not available."
  have curl || die "curl is required."
  [[ -d "$SELFSTEAL_DIR" ]] || die "nginx-selfsteal not found: $SELFSTEAL_DIR"
  [[ -f "$SELFSTEAL_CONF" ]] || die "selfsteal.conf not found: $SELFSTEAL_CONF"
  docker ps --format '{{.Names}}' | grep -qx 'nginx-selfsteal' ||
    warn "Container nginx-selfsteal is not currently running."
}

check_compose_override_support() {
  local raw major minor patch
  raw="$(docker compose version --short 2>/dev/null | sed 's/^v//')"
  major="${raw%%.*}"
  minor="$(printf '%s' "$raw" | cut -d. -f2)"
  patch="$(printf '%s' "$raw" | cut -d. -f3 | sed 's/[^0-9].*//')"
  major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"
  if (( major < 2 || (major == 2 && minor < 24) || (major == 2 && minor == 24 && patch < 4) )); then
    die "Docker Compose ${raw} is too old. v2.24.4+ is required for !override."
  fi
}

prepare_repo() {
  if [[ ! -f "$JITSI_DIR/docker-compose.yml" || ! -f "$JITSI_DIR/env.example" ]]; then
    log "Downloading docker-jitsi-meet..."
    rm -rf "$JITSI_DIR"
    git clone --depth 1 https://github.com/jitsi/docker-jitsi-meet.git "$JITSI_DIR"
  fi

  cd "$JITSI_DIR"
  [[ -f .env ]] || cp env.example .env
  [[ -x gen-passwords.sh ]] || chmod +x gen-passwords.sh
}

clean_generated_config() {
  log "Stopping current Jitsi stack..."
  if [[ -f "$JITSI_DIR/docker-compose.yml" ]]; then
    cd "$JITSI_DIR"
    if [[ -f "$OVERRIDE_FILE" ]]; then
      docker compose -f docker-compose.yml -f "$OVERRIDE_FILE" down --remove-orphans || true
    else
      docker compose down --remove-orphans || true
    fi
  fi

  if [[ -d "$JITSI_CFG" ]]; then
    local backup="${JITSI_CFG}.bak.$(date +%Y%m%d-%H%M%S)"
    log "Backing up old generated Jitsi config to $backup"
    mv "$JITSI_CFG" "$backup"
  fi
}

prepare_env() {
  cd "$JITSI_DIR"

  # Generate secrets if missing/empty. Running the official helper repeatedly is harmless
  # for already-populated values because it only fills expected password variables.
  ./gen-passwords.sh

  set_env CONFIG "$JITSI_CFG"
  set_env TZ "Europe/Moscow"
  set_env PUBLIC_URL "https://${DOMAIN}"
  set_env HTTP_PORT "$HTTP_PORT"
  set_env HTTPS_PORT "8443"
  set_env DISABLE_HTTPS "1"
  set_env ENABLE_HTTP_REDIRECT "0"
  set_env ENABLE_LETSENCRYPT "0"
  # This integration is intentionally IPv4-only. Prevent Jitsi nginx/Prosody
  # from trying to bind IPv6 sockets on hosts where IPv6 is disabled.
  set_env ENABLE_IPV6 "0"
  set_env JVB_ADVERTISE_IPS "$PUBLIC_IP"
  set_env JVB_PORT "$JVB_PORT"
  set_env JITSI_IMAGE_VERSION "stable"

  if [[ "$AUTH" == "1" ]]; then
    set_env ENABLE_AUTH "1"
    set_env AUTH_TYPE "internal"
    set_env ENABLE_GUESTS "1"
  else
    set_env ENABLE_AUTH "0"
    set_env ENABLE_GUESTS "0"
  fi

  # Current official images need these config directories writable.
  install -d -m 755 \
    "$JITSI_CFG/web" \
    "$JITSI_CFG/transcripts" \
    "$JITSI_CFG/prosody/config" \
    "$JITSI_CFG/prosody/prosody-plugins-custom" \
    "$JITSI_CFG/jicofo" \
    "$JITSI_CFG/jvb" \
    "$JITSI_CFG/storage/prosody"

  # /var/lib/prosody is a host bind mount. Current Prosody images run as
  # uid/gid 1000 and fail fast when this storage is root-owned and not writable.
  chown -R 1000:1000 "$JITSI_CFG/storage/prosody"
}

write_override() {
  cat > "$JITSI_DIR/$OVERRIDE_FILE" <<EOF
services:
  web:
    ports: !override
      - "127.0.0.1:\${HTTP_PORT}:8000"
EOF
}

verify_effective_compose() {
  local cfg
  cfg="$(compose config)"

  # Exactly one host publication of HTTP_PORT for web, bound to loopback.
  local webblock
  webblock="$(printf '%s\n' "$cfg" | awk '
    /^  web:$/ {p=1}
    p {print}
    p && /^networks:$/ {exit}
  ')"

  printf '%s\n' "$webblock" | grep -q 'host_ip: 127.0.0.1' ||
    die "Effective Compose does not bind Jitsi web to 127.0.0.1."

  local count
  count="$(printf '%s\n' "$webblock" | grep -c "published: \"${HTTP_PORT}\"" || true)"
  [[ "$count" -eq 1 ]] ||
    die "Effective Compose contains ${count} publications of host port ${HTTP_PORT}; expected exactly 1."

  printf '%s\n' "$webblock" | grep -q 'target: 8000' ||
    die "Effective Compose does not map host ${HTTP_PORT} to container port 8000."

  if printf '%s\n' "$webblock" | grep -q 'published: "8443"'; then
    die "Jitsi HTTPS 8443 is still published. Override was not applied correctly."
  fi
}

find_cert_paths() {
  CERT_PATH="$(awk '/ssl_certificate[[:space:]]+/ && $0 !~ /ssl_certificate_key/ {gsub(/;/,"",$2); print $2; exit}' "$SELFSTEAL_CONF" || true)"
  KEY_PATH="$(awk '/ssl_certificate_key[[:space:]]+/ {gsub(/;/,"",$2); print $2; exit}' "$SELFSTEAL_CONF" || true)"
  [[ -n "$CERT_PATH" && -n "$KEY_PATH" ]] ||
    die "Could not detect ssl_certificate / ssl_certificate_key in $SELFSTEAL_CONF."
}

write_nginx() {
  find_cert_paths

  local backup="${SELFSTEAL_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$SELFSTEAL_CONF" "$backup"
  log "nginx config backup: $backup"

  # This config intentionally keeps public 443 on Xray. nginx receives the
  # selfsteal fallback on the Unix socket and proxies only to local Jitsi HTTP.
  cat > "$SELFSTEAL_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate ${CERT_PATH};
    ssl_certificate_key ${KEY_PATH};

    set_real_ip_from unix:;
    real_ip_header proxy_protocol;

    location = /xmpp-websocket {
        proxy_pass http://127.0.0.1:${HTTP_PORT}/xmpp-websocket;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location ~ ^/colibri-ws/ {
        proxy_pass http://127.0.0.1:${HTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location / {
        proxy_pass http://127.0.0.1:${HTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

  if ! docker exec nginx-selfsteal nginx -t; then
    warn "nginx -t failed; restoring previous config."
    cp -a "$backup" "$SELFSTEAL_CONF"
    docker exec nginx-selfsteal nginx -t || true
    die "nginx configuration rejected."
  fi

  docker exec nginx-selfsteal nginx -s reload
}

start_jitsi() {
  # Avoid misleading "port already allocated" if an old failed web container exists.
  docker rm -f jitsi-web-1 >/dev/null 2>&1 || true

  log "Starting Jitsi..."
  if ! compose up -d; then
    warn "First start failed. Removing failed web container and retrying once..."
    docker rm -f jitsi-web-1 >/dev/null 2>&1 || true
    sleep 2
    compose up -d
  fi
}

wait_for_stack() {
  log "Waiting for Jitsi HTTP..."
  local i
  for i in $(seq 1 45); do
    if curl -fsS --max-time 3 "http://127.0.0.1:${HTTP_PORT}/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  compose ps || true
  warn "Prosody logs:"
  docker logs jitsi-prosody-1 --tail 50 2>&1 || true
  warn "Web logs:"
  docker logs jitsi-web-1 --tail 50 2>&1 || true
  die "Jitsi HTTP did not become ready on 127.0.0.1:${HTTP_PORT}."
}

check_udp() {
  if docker ps --format '{{.Names}} {{.Ports}}' |
       grep -E "jitsi-jvb.*(^|[, ])(0\.0\.0\.0:|\[::\]:)?${JVB_PORT}->10000/udp" >/dev/null; then
    log "JVB UDP/${JVB_PORT} is published."
  else
    warn "Could not confirm JVB UDP/${JVB_PORT} publication."
  fi
}

install_cmd() {
  check_prereqs
  check_compose_override_support
  detect_domain
  detect_ip

  [[ -n "$DOMAIN" ]] || die "Domain not detected. Use --domain meet.example.com"
  [[ -n "$PUBLIC_IP" ]] || die "Public IPv4 not detected. Use --ip x.x.x.x"

  log "Domain: $DOMAIN"
  log "Public IPv4: $PUBLIC_IP"
  log "Public TCP/443 remains owned by Xray Reality."
  log "Jitsi web will listen only on 127.0.0.1:${HTTP_PORT}."
  log "JVB media will use UDP/${JVB_PORT}."

  prepare_repo

  if [[ "$CLEAN" == "1" ]]; then
    clean_generated_config
    # .env survives because it is in /opt/jitsi; regenerate all secrets after
    # removing generated runtime config.
  fi

  prepare_env
  write_override
  verify_effective_compose

  # Save early so an interrupted Docker start can be repaired later.
  save_state

  start_jitsi
  wait_for_stack
  check_udp
  write_nginx

  log "Installation complete."
  log "Open: https://${DOMAIN}"
  if [[ "$AUTH" == "1" ]]; then
    log "Create a host account with:"
    printf '  docker exec -it jitsi-prosody-1 prosodyctl --config /config/prosody.cfg.lua register USER %s PASSWORD\n' "$DOMAIN"
  fi
}

repair_cmd() {
  check_prereqs
  check_compose_override_support
  [[ -f "$STATE_FILE" ]] || die "State not found. Run install with --domain and --ip first."
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  prepare_repo
  prepare_env
  write_override
  verify_effective_compose
  start_jitsi
  wait_for_stack
  check_udp
  write_nginx
  log "Repair complete."
}

status_cmd() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
  printf 'Version: %s\n' "$VERSION"
  printf 'Domain: %s\n' "${DOMAIN:-unknown}"
  printf 'Public IPv4: %s\n' "${PUBLIC_IP:-unknown}"
  printf 'Auth: %s\n\n' "${AUTH:-unknown}"

  docker ps --filter name=nginx-selfsteal --format 'nginx-selfsteal: {{.Status}}' || true
  printf '\n'
  if [[ -f "$JITSI_DIR/docker-compose.yml" && -f "$JITSI_DIR/$OVERRIDE_FILE" ]]; then
    compose ps || true
  fi
  printf '\n'
  if curl -fsS --max-time 3 "http://127.0.0.1:${HTTP_PORT}/" >/dev/null 2>&1; then
    echo "Local Jitsi HTTP: OK (127.0.0.1:${HTTP_PORT})"
  else
    echo "Local Jitsi HTTP: FAILED"
  fi
  check_udp
}

logs_cmd() {
  local service="${1:-}"
  case "$service" in
    web) docker logs -f --tail 200 jitsi-web-1 ;;
    prosody) docker logs -f --tail 200 jitsi-prosody-1 ;;
    jicofo) docker logs -f --tail 200 jitsi-jicofo-1 ;;
    jvb) docker logs -f --tail 200 jitsi-jvb-1 ;;
    "") compose logs -f --tail 100 ;;
    *) die "Unknown service: $service" ;;
  esac
}

update_cmd() {
  [[ -f "$STATE_FILE" ]] || die "State not found."
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  prepare_repo
  prepare_env
  write_override
  verify_effective_compose
  compose pull
  compose up -d
  wait_for_stack
  check_udp
  log "Jitsi images updated."
}

uninstall_cmd() {
  warn "This removes the Jitsi stack and generated Jitsi config only."
  if [[ -f "$JITSI_DIR/docker-compose.yml" ]]; then
    cd "$JITSI_DIR"
    if [[ -f "$OVERRIDE_FILE" ]]; then
      docker compose -f docker-compose.yml -f "$OVERRIDE_FILE" down --remove-orphans || true
    else
      docker compose down --remove-orphans || true
    fi
  fi
  rm -rf "$JITSI_CFG"
  rm -f "$STATE_FILE"
  log "Jitsi removed. nginx-selfsteal/Remnawave/Xray were not removed."
  warn "The nginx selfsteal config was not automatically restored. Use its .bak file if needed."
}

need_root

CMD="${1:-}"
shift || true

case "$CMD" in
  setup) setup_cmd ;;
  install)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --domain) DOMAIN="${2:-}"; shift 2 ;;
        --ip) PUBLIC_IP="${2:-}"; shift 2 ;;
        --auth) AUTH="1"; shift ;;
        --no-auth) AUTH="0"; shift ;;
        --clean) CLEAN="1"; shift ;;
        --http-port) HTTP_PORT="${2:-}"; valid_port "$HTTP_PORT" || die "Invalid --http-port"; shift 2 ;;
        --jvb-port) JVB_PORT="${2:-}"; valid_port "$JVB_PORT" || die "Invalid --jvb-port"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
      esac
    done
    install_cmd
    ;;
  repair) repair_cmd ;;
  status) status_cmd ;;
  logs) logs_cmd "${1:-}" ;;
  update) update_cmd ;;
  update-script) update_script_cmd ;;
  version) version_cmd ;;
  uninstall) uninstall_cmd ;;
  -h|--help|"") usage ;;
  *) die "Unknown command: $CMD" ;;
esac
