#!/usr/bin/env bash
# install.sh — Triton Manage Server installer.
#
# Idempotent. Generates secrets on first run, reuses .env afterwards.
# Container-based via Podman or Docker (auto-detected).
#
# Usage:
#   sudo bash install.sh --license-file /path/to/bundle/license.lic
#
# The license bundle (provided by your vendor) is a single file:
#   license.lic   — signed offline licence token
# The vendor's public key is baked into the image at build time.
#
# Flags:
#   --license-file PATH             Path to license.lic from your vendor bundle. Required.
#   --gateway-hostname HOST         Agent mTLS hostname (defaults to current FQDN).
#   --manage-host-ip IP             Host LAN IP — used for "+ This machine".
#   --port PORT                     Host port for the web UI (default: 8082).
#   --image TAG                     Pin a specific manage-server image tag.
#   --no-tls                        Skip the TLS-required sanity check (dev).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" &>/dev/null && pwd)"
cd "$SCRIPT_DIR"

info() { printf '[manage-server] %s\n' "$*"; }
die()  { printf '[manage-server] error: %s\n' "$*" >&2; exit 1; }

# ── arg parsing ──────────────────────────────────────────────────────────
LICENSE_FILE=""
GATEWAY_HOST=""
HOST_IP=""
PORT=""
IMAGE=""
NO_TLS=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --license-file)          LICENSE_FILE="$2";       shift 2 ;;
        --gateway-hostname)      GATEWAY_HOST="$2";       shift 2 ;;
        --manage-host-ip)        HOST_IP="$2";            shift 2 ;;
        --port)                  PORT="$2";               shift 2 ;;
        --image)                 IMAGE="$2";              shift 2 ;;
        --no-tls)                NO_TLS=1;                shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# //;s/^#//'; exit 0 ;;
        *) die "unknown flag: $1 (try --help)" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "must run as root"

# ── validate license bundle ──────────────────────────────────────────────
[[ -n "$LICENSE_FILE" ]] || die "--license-file is required (path to license.lic from your vendor bundle)"
[[ -f "$LICENSE_FILE" ]] || die "license file not found: $LICENSE_FILE"

LICENSE_TOKEN="$(cat "$LICENSE_FILE")"

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
        -e "s|^TRITON_VAULT_KEY=.*|TRITON_VAULT_KEY=$VAULT_KEY|" \
        "$ENV_FILE"
    info "secrets generated"

    sed -i "s|^TRITON_LICENSE_KEY=.*|TRITON_LICENSE_KEY=$LICENSE_TOKEN|" "$ENV_FILE"
    info "licence configured"

    [[ -n "$GATEWAY_HOST" ]] && sed -i "s|^TRITON_MANAGE_GATEWAY_HOSTNAME=.*|TRITON_MANAGE_GATEWAY_HOSTNAME=$GATEWAY_HOST|" "$ENV_FILE"
    [[ -n "$HOST_IP"            ]] && sed -i "s|^TRITON_MANAGE_HOST_IP=.*|TRITON_MANAGE_HOST_IP=$HOST_IP|" "$ENV_FILE"
    [[ -n "$PORT"               ]] && sed -i "s|^TRITON_MANAGE_HOST_PORT=.*|TRITON_MANAGE_HOST_PORT=$PORT|" "$ENV_FILE"
    [[ -n "$IMAGE"              ]] && sed -i "s|^TRITON_MANAGE_IMAGE=.*|TRITON_MANAGE_IMAGE=$IMAGE|" "$ENV_FILE"

    info ".env created at $ENV_FILE"
    info "  back this up — it contains the JWT signing key, worker key, and vault key"
else
    info "reusing existing .env at $ENV_FILE"
fi

# ── pull latest image ────────────────────────────────────────────────────
info "pulling latest image..."
"${COMPOSE[@]}" --env-file "$ENV_FILE" pull manage-server

# ── start ────────────────────────────────────────────────────────────────
info "starting containers..."
"${COMPOSE[@]}" --env-file "$ENV_FILE" up -d

# ── wait for health ──────────────────────────────────────────────────────
HOST_PORT=$(grep -E '^TRITON_MANAGE_HOST_PORT=' "$ENV_FILE" | cut -d= -f2)
HOST_PORT=${HOST_PORT:-8082}

info "waiting for manage server to become healthy on :${HOST_PORT}..."
for i in $(seq 1 30); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${HOST_PORT}/" || echo "000")
    if [[ "$CODE" == "302" || "$CODE" == "200" ]]; then
        info "manage server is up"
        break
    fi
    sleep 2
done

info ""
info "Installation complete. Next steps:"
info "  1. Open http://localhost:${HOST_PORT} (or your public URL)"
info "  2. Complete the setup wizard"
info "  3. Configure TLS via reverse proxy (see docs)"
info ""

# ── machine ID ───────────────────────────────────────────────────────────
# Print the SHA-3-256 hash of /etc/machine-id so the customer can share
# it with the vendor when requesting an offline .lic bound to this host.
# The hash is stable: /etc/machine-id never changes after OS installation.
if [[ -f /etc/machine-id ]]; then
    MACHINE_ID_RAW=$(cat /etc/machine-id | tr -d '[:space:]')
    if command -v python3 >/dev/null 2>&1; then
        MACHINE_ID_HASH=$(python3 -c "import hashlib; print(hashlib.sha3_256('${MACHINE_ID_RAW}'.encode()).hexdigest())")
    elif command -v sha3sum >/dev/null 2>&1; then
        MACHINE_ID_HASH=$(echo -n "$MACHINE_ID_RAW" | sha3sum -a 256 | awk '{print $1}')
    elif command -v openssl >/dev/null 2>&1; then
        MACHINE_ID_HASH=$(printf '%s' "${MACHINE_ID_RAW}" | openssl dgst -sha3-256 -hex 2>/dev/null | awk '{print $2}')
    else
        MACHINE_ID_HASH=""
    fi
    if [[ -n "$MACHINE_ID_HASH" ]]; then
        info "── Host Machine ID ──────────────────────────────────────────────────────"
        info "  Provide this value to your vendor when requesting a host-bound .lic file."
        info "  Machine ID (SHA-3-256): $MACHINE_ID_HASH"
        info "────────────────────────────────────────────────────────────────────────"
    fi
fi
