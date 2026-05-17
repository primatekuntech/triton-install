#!/usr/bin/env bash
# upgrade.sh — pull the latest manage-server image and restart.
#
# Takes a pre-upgrade pg_dump. DB schema migrations run on startup.
#
# Usage:
#   sudo bash upgrade.sh                # latest from ghcr.io
#   sudo bash upgrade.sh --image TAG    # pin a specific image
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "$SCRIPT_DIR"

info() { printf '[manage-server] %s\n' "$*"; }
die()  { printf '[manage-server] error: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root"
[[ -f .env     ]] || die ".env not found — run install.sh first"

IMAGE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# //;s/^#//'; exit 0 ;;
        *) die "unknown flag: $1" ;;
    esac
done

if [[ -n "$IMAGE" ]]; then
    sed -i "s|^TRITON_MANAGE_IMAGE=.*|TRITON_MANAGE_IMAGE=$IMAGE|" .env
    info "pinned image to $IMAGE"
fi

if command -v podman-compose >/dev/null 2>&1; then COMPOSE=(podman-compose)
elif podman compose version >/dev/null 2>&1; then  COMPOSE=(podman compose)
elif docker compose version >/dev/null 2>&1; then  COMPOSE=(docker compose)
else die "no compose runtime found"; fi

info "pre-upgrade DB backup..."
mkdir -p /var/backups/triton
DUMP_FILE="/var/backups/triton/manage-pre-upgrade-$(date +%F-%H%M%S).sql.gz"
podman exec triton-manage-db pg_dump -U triton triton_manage 2>/dev/null \
    | gzip > "$DUMP_FILE" || die "pg_dump failed — aborting upgrade"
info "  saved: $DUMP_FILE"

info "pulling latest image..."
"${COMPOSE[@]}" --env-file .env pull manage-server

info "recreating manage-server container..."
"${COMPOSE[@]}" --env-file .env up -d --no-deps manage-server

HOST_PORT=$(grep -E '^TRITON_MANAGE_HOST_PORT=' .env | cut -d= -f2)
HOST_PORT=${HOST_PORT:-8082}

info "waiting for new container to become healthy..."
for i in $(seq 1 30); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${HOST_PORT}/" || echo "000")
    if [[ "$CODE" == "302" || "$CODE" == "200" ]]; then
        info "upgrade complete"
        exit 0
    fi
    sleep 2
done
die "new container did not become healthy in 60s — check logs"
