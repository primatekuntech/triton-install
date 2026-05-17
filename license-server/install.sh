#!/usr/bin/env bash
# install.sh — Triton License Server installer.
#
# Idempotent. Generates secrets on first run, reuses .env on subsequent runs.
# Container-based via Podman or Docker (auto-detected).
#
# Usage:
#   sudo bash install.sh                         # interactive defaults
#   sudo bash install.sh --admin-email a@b.com   # set initial admin email
#   sudo bash install.sh --image TAG             # pin a specific image
#   sudo bash install.sh --public-url URL        # set TRITON_LICENSE_SERVER_PUBLIC_URL
#   sudo bash install.sh --no-tls                # skip TLS check (dev)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "$SCRIPT_DIR"

info() { printf '[license-server] %s\n' "$*"; }
die()  { printf '[license-server] error: %s\n' "$*" >&2; exit 1; }

# ── arg parsing ──────────────────────────────────────────────────────────
ADMIN_EMAIL=""
PUBLIC_URL=""
IMAGE=""
NO_TLS=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --admin-email)  ADMIN_EMAIL="$2"; shift 2 ;;
        --public-url)   PUBLIC_URL="$2";  shift 2 ;;
        --image)        IMAGE="$2";       shift 2 ;;
        --no-tls)       NO_TLS=1;         shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# //;s/^#//'; exit 0 ;;
        *)
            die "unknown flag: $1 (try --help)" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "must run as root"

# ── runtime detection (podman > docker) ──────────────────────────────────
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
info "using runtime: $RUNTIME ($(command -v $RUNTIME))"

# ── .env bootstrap ───────────────────────────────────────────────────────
ENV_FILE="$SCRIPT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    info "writing .env from env.template (first install)"
    cp env.template "$ENV_FILE"
    chmod 600 "$ENV_FILE"

    # Auto-generate secrets.
    PG_PASS=$(openssl rand -hex 24)

    # Ed25519 keypair: seed (32B) || pub (32B) = 64B = 128 hex chars.
    # openssl emits PKCS#8 PEM; pull the seed out, re-derive the pub half via Go-style
    # ed25519.NewKeyFromSeed at server startup. We just need the 128-hex format here.
    TMP_PEM=$(mktemp)
    trap 'rm -f "$TMP_PEM"' EXIT
    openssl genpkey -algorithm ed25519 -out "$TMP_PEM" 2>/dev/null
    SEED_HEX=$(openssl pkey -in "$TMP_PEM" -text -noout 2>/dev/null \
        | awk '/priv:/{found=1; next} found && /pub:/{exit} found' \
        | tr -d ' :\n' | head -c 64)
    PUB_HEX=$(openssl pkey -in "$TMP_PEM" -pubout -outform DER 2>/dev/null \
        | tail -c 32 | xxd -p -c 64 | tr -d '\n')
    SIGNING_KEY="${SEED_HEX}${PUB_HEX}"

    [[ ${#SIGNING_KEY} -eq 128 ]] || die "Ed25519 keygen produced bad length (${#SIGNING_KEY})"

    ADMIN_PASS=$(openssl rand -base64 24 | tr -d '\n=+/' | head -c 28)

    sed -i \
        -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$PG_PASS|" \
        -e "s|^TRITON_LICENSE_SERVER_SIGNING_KEY=.*|TRITON_LICENSE_SERVER_SIGNING_KEY=$SIGNING_KEY|" \
        -e "s|^TRITON_LICENSE_SERVER_ADMIN_PASSWORD=.*|TRITON_LICENSE_SERVER_ADMIN_PASSWORD=$ADMIN_PASS|" \
        "$ENV_FILE"

    [[ -n "$ADMIN_EMAIL" ]] && sed -i "s|^TRITON_LICENSE_SERVER_ADMIN_EMAIL=.*|TRITON_LICENSE_SERVER_ADMIN_EMAIL=$ADMIN_EMAIL|" "$ENV_FILE"
    [[ -n "$PUBLIC_URL"  ]] && sed -i "s|^TRITON_LICENSE_SERVER_PUBLIC_URL=.*|TRITON_LICENSE_SERVER_PUBLIC_URL=$PUBLIC_URL|"   "$ENV_FILE"
    [[ -n "$IMAGE"       ]] && sed -i "s|^TRITON_LICENSE_IMAGE=.*|TRITON_LICENSE_IMAGE=$IMAGE|"                                "$ENV_FILE"
    [[ $NO_TLS -eq 1     ]] && sed -i "s|^TRITON_LICENSE_SERVER_ALLOW_INSECURE=.*|TRITON_LICENSE_SERVER_ALLOW_INSECURE=1|"     "$ENV_FILE"

    info ".env created at $ENV_FILE"
    info "INITIAL ADMIN PASSWORD: $ADMIN_PASS"
    info "  rotate after first login (Account → Change password)"
else
    info "reusing existing .env at $ENV_FILE"
fi

# ── binary directory ─────────────────────────────────────────────────────
BIN_DIR_HOST=$(grep -E '^TRITON_LICENSE_SERVER_HOST_BIN_DIR=' "$ENV_FILE" | cut -d= -f2)
BIN_DIR_HOST="${BIN_DIR_HOST:-/opt/triton/binaries}"
if [[ ! -d "$BIN_DIR_HOST" ]]; then
    info "creating binary directory: $BIN_DIR_HOST"
    mkdir -p "$BIN_DIR_HOST"
    chmod 755 "$BIN_DIR_HOST"
fi
info "binary directory: $BIN_DIR_HOST"

# ── start ────────────────────────────────────────────────────────────────
info "starting containers..."
"${COMPOSE[@]}" --env-file "$ENV_FILE" up -d

info "waiting for license server to become healthy..."
HOST_PORT=$(grep -E '^TRITON_LICENSE_SERVER_HOST_PORT=' "$ENV_FILE" | cut -d= -f2)
HOST_PORT=${HOST_PORT:-8081}

for i in $(seq 1 30); do
    if curl -sf "http://localhost:${HOST_PORT}/api/v1/health" >/dev/null 2>&1; then
        info "license server is up: http://localhost:${HOST_PORT}"
        break
    fi
    sleep 2
done

info "done. Admin UI: http://localhost:${HOST_PORT}/ui/"
info "  login as: $(grep ADMIN_EMAIL "$ENV_FILE" | cut -d= -f2)"
info "  see manage-server.md to wire a manage server to this licence server."
