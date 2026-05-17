#!/usr/bin/env bash
# install.sh — Triton Manage Server installer.
#
# Idempotent. Generates secrets on first run, reuses .env afterwards.
# Container-based via Podman or Docker (auto-detected).
#
# Usage:
#   sudo bash install.sh \
#       --license-server-pubkey HEX \
#       --license-server-url    https://license.yourvendor.com \
#       --gateway-hostname      manage.customer.com
#
# Flags:
#   --license-server-pubkey HEX     Ed25519 public half (64 hex chars). REQUIRED.
#                                   Last 64 chars of vendor's TRITON_LICENSE_SERVER_SIGNING_KEY.
#   --license-server-url URL        URL of vendor's License Server.
#   --license-token TOKEN           Pre-fill activation token (else use the setup wizard).
#   --gateway-hostname HOST         Agent mTLS hostname (defaults to current FQDN).
#   --manage-host-ip IP             Host LAN IP — used for "+ This machine".
#   --image TAG                     Pin a specific manage-server image.
#   --no-tls                        Skip the TLS-required sanity check (dev).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "$SCRIPT_DIR"

info() { printf '[manage-server] %s\n' "$*"; }
die()  { printf '[manage-server] error: %s\n' "$*" >&2; exit 1; }

# ── arg parsing ──────────────────────────────────────────────────────────
LIC_PUBKEY=""
LIC_URL=""
LIC_TOKEN=""
GATEWAY_HOST=""
HOST_IP=""
IMAGE=""
NO_TLS=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --license-server-pubkey) LIC_PUBKEY="$2";   shift 2 ;;
        --license-server-url)    LIC_URL="$2";      shift 2 ;;
        --license-token)         LIC_TOKEN="$2";    shift 2 ;;
        --gateway-hostname)      GATEWAY_HOST="$2"; shift 2 ;;
        --manage-host-ip)        HOST_IP="$2";      shift 2 ;;
        --image)                 IMAGE="$2";        shift 2 ;;
        --no-tls)                NO_TLS=1;          shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# //;s/^#//'; exit 0 ;;
        *) die "unknown flag: $1 (try --help)" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "must run as root"

# ── runtime detection ────────────────────────────────────────────────────
if command -v podman-compose >/dev/null 2>&1; then
    COMPOSE=(podman-compose)
    RUNTIME=podman
elif podman compose version >/dev/null 2>&1; then
    COMPOSE=(podman compose)
    RUNTIME=podman
elif docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
    RUNTIME=docker
else
    die "no compose runtime found. Install podman-compose or docker compose."
fi
info "using runtime: $RUNTIME"

# ── .env bootstrap ───────────────────────────────────────────────────────
ENV_FILE="$SCRIPT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    [[ -n "$LIC_PUBKEY" ]] || die "--license-server-pubkey required on first install"
    [[ ${#LIC_PUBKEY} -eq 64 ]] || die "license-server-pubkey must be 64 hex chars"

    info "writing .env from env.template"
    cp env.template "$ENV_FILE"
    chmod 600 "$ENV_FILE"

    PG_PASS=$(openssl rand -hex 24)
    JWT_KEY=$(openssl rand -hex 32)
    WORKER_KEY=$(openssl rand -hex 16)
    VAULT_KEY=$(openssl rand -hex 32)

    sed -i \
        -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$PG_PASS|" \
        -e "s|^TRITON_MANAGE_JWT_SIGNING_KEY=.*|TRITON_MANAGE_JWT_SIGNING_KEY=$JWT_KEY|" \
        -e "s|^TRITON_MANAGE_WORKER_KEY=.*|TRITON_MANAGE_WORKER_KEY=$WORKER_KEY|" \
        -e "s|^TRITON_MANAGE_LICENSE_SERVER_PUBKEY=.*|TRITON_MANAGE_LICENSE_SERVER_PUBKEY=$LIC_PUBKEY|" \
        -e "s|^TRITON_VAULT_KEY=.*|TRITON_VAULT_KEY=$VAULT_KEY|" \
        "$ENV_FILE"
    info "vault key generated (PostgreSQL AES-256-GCM)"

    [[ -n "$LIC_URL"      ]] && sed -i "s|^TRITON_LICENSE_SERVER_URL=.*|TRITON_LICENSE_SERVER_URL=$LIC_URL|" "$ENV_FILE"
    [[ -n "$LIC_TOKEN"    ]] && sed -i "s|^TRITON_LICENSE_TOKEN=.*|TRITON_LICENSE_TOKEN=$LIC_TOKEN|"         "$ENV_FILE"
    [[ -n "$GATEWAY_HOST" ]] && sed -i "s|^TRITON_MANAGE_GATEWAY_HOSTNAME=.*|TRITON_MANAGE_GATEWAY_HOSTNAME=$GATEWAY_HOST|" "$ENV_FILE"
    [[ -n "$HOST_IP"      ]] && sed -i "s|^TRITON_MANAGE_HOST_IP=.*|TRITON_MANAGE_HOST_IP=$HOST_IP|"         "$ENV_FILE"
    [[ -n "$IMAGE"        ]] && sed -i "s|^TRITON_MANAGE_IMAGE=.*|TRITON_MANAGE_IMAGE=$IMAGE|"               "$ENV_FILE"

    info ".env created at $ENV_FILE"
    info "  back this up: it contains the JWT signing key, worker key, and vault key"
else
    info "reusing existing .env at $ENV_FILE"
fi

# ── start ────────────────────────────────────────────────────────────────
info "starting containers..."
"${COMPOSE[@]}" --env-file "$ENV_FILE" up -d

# ── wait for health ──────────────────────────────────────────────────────
HOST_PORT=$(grep -E '^TRITON_MANAGE_HOST_PORT=' "$ENV_FILE" | cut -d= -f2)
HOST_PORT=${HOST_PORT:-8082}

info "waiting for manage server to become healthy on :${HOST_PORT}..."
for i in $(seq 1 30); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${HOST_PORT}/" || echo "000")
    # 302 (redirect to setup or login) means the server is up.
    if [[ "$CODE" == "302" || "$CODE" == "200" ]]; then
        info "manage server is up: http://localhost:${HOST_PORT}"
        break
    fi
    sleep 2
done

info ""
info "Next steps:"
info "  1. Open http://localhost:${HOST_PORT} (or your public URL)"
info "  2. Complete the setup wizard: create the admin user, paste the licence token"
info "  3. Configure TLS via reverse proxy (see prerequisites.md)"
info ""
info "  License Server URL: $(grep ^TRITON_LICENSE_SERVER_URL= $ENV_FILE | cut -d= -f2-)"
info "  Gateway hostname:   $(grep ^TRITON_MANAGE_GATEWAY_HOSTNAME= $ENV_FILE | cut -d= -f2)"
