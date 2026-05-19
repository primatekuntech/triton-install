#!/usr/bin/env bash
# upgrade.sh — pull the latest manage-server image and restart.
#
# Takes a pre-upgrade pg_dump backup. DB schema migrations run automatically
# on container startup — no manual migration step required.
#
# Usage:
#   sudo bash upgrade.sh                # latest from ghcr.io
#   sudo bash upgrade.sh --image TAG    # pin a specific image tag
#   sudo bash upgrade.sh --port PORT    # change the web UI host port
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" &>/dev/null && pwd)"
cd "$SCRIPT_DIR"

info() { printf '[manage-server] %s\n' "$*"; }
die()  { printf '[manage-server] error: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root"
[[ -f .env     ]] || die ".env not found — run install.sh first"

# ── arg parsing ───────────────────────────────────────────────────────────
IMAGE=""
PORT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --port)  PORT="$2";  shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# //;s/^#//'; exit 0 ;;
        *) die "unknown flag: $1" ;;
    esac
done

# ── runtime detection ─────────────────────────────────────────────────────
if command -v podman-compose >/dev/null 2>&1; then COMPOSE=(podman-compose); RUNTIME=podman
elif podman compose version >/dev/null 2>&1;  then COMPOSE=(podman compose);  RUNTIME=podman
elif docker compose version >/dev/null 2>&1;  then COMPOSE=(docker compose);  RUNTIME=docker
else die "no compose runtime found"; fi

# ── pin image if requested ────────────────────────────────────────────────
if [[ -n "$IMAGE" ]]; then
    sed -i "s|^TRITON_MANAGE_IMAGE=.*|TRITON_MANAGE_IMAGE=$IMAGE|" .env
    info "pinned image to $IMAGE"
fi
if [[ -n "$PORT" ]]; then
    sed -i "s|^TRITON_MANAGE_HOST_PORT=.*|TRITON_MANAGE_HOST_PORT=$PORT|" .env
    info "host port set to $PORT"
fi

# ── pre-upgrade DB backup ─────────────────────────────────────────────────
case "$(uname -s)" in
    Linux)  BACKUP_DIR="/var/backups/triton" ;;
    Darwin) BACKUP_DIR="${HOME}/Library/Application Support/triton/backups" ;;
    *)      BACKUP_DIR="$SCRIPT_DIR/backups" ;;
esac
mkdir -p "$BACKUP_DIR"
DUMP_FILE="${BACKUP_DIR}/manage-pre-upgrade-$(date +%F-%H%M%S).sql.gz"

info "pre-upgrade DB backup..."
PG_USER=$(grep -E '^POSTGRES_USER=' .env | cut -d= -f2)
PG_USER=${PG_USER:-triton}
PG_DB=$(grep -E '^POSTGRES_DB=' .env | cut -d= -f2)
PG_DB=${PG_DB:-triton_manage}

"$RUNTIME" exec triton-manage-db pg_dump -U "$PG_USER" "$PG_DB" 2>/dev/null \
    | gzip > "$DUMP_FILE" || die "pg_dump failed — aborting upgrade (DB container may not be running)"
info "  backup saved: $DUMP_FILE"

# ── pull new image ────────────────────────────────────────────────────────
info "pulling latest image..."
"${COMPOSE[@]}" --env-file .env pull manage-server

# ── recreate container (DB migrations run on startup) ─────────────────────
info "recreating manage-server container..."
info "  DB schema migrations will run automatically on startup"
"${COMPOSE[@]}" --env-file .env up -d --no-deps manage-server

# ── wait for healthy (confirms migrations succeeded) ──────────────────────
HOST_PORT=$(grep -E '^TRITON_MANAGE_HOST_PORT=' .env | cut -d= -f2)
HOST_PORT=${HOST_PORT:-8082}

info "waiting for server to become healthy on :${HOST_PORT}..."
for i in $(seq 1 30); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${HOST_PORT}/" || echo "000")
    if [[ "$CODE" == "302" || "$CODE" == "200" ]]; then
        info "upgrade complete — server is healthy (migrations applied)"
        info "  rollback if needed: gunzip -c ${DUMP_FILE} | $RUNTIME exec -i triton-manage-db psql -U ${PG_USER} ${PG_DB}"
        exit 0
    fi
    sleep 2
done
die "server did not become healthy in 60s — check logs: $RUNTIME logs triton-manageserver"
