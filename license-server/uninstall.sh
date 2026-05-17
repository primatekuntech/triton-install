#!/usr/bin/env bash
# uninstall.sh — stop and remove License Server containers.
#
# By default, KEEPS the PostgreSQL volume (license data). Pass --purge-data
# to delete the volume as well — irreversible.
#
# Usage:
#   sudo bash uninstall.sh             # stop + remove containers, keep DB volume
#   sudo bash uninstall.sh --purge-data  # also delete DB volume (DESTRUCTIVE)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "$SCRIPT_DIR"

info() { printf '[license-server] %s\n' "$*"; }
die()  { printf '[license-server] error: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root"

PURGE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge-data) PURGE=1; shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# //;s/^#//'; exit 0 ;;
        *) die "unknown flag: $1" ;;
    esac
done

if command -v podman-compose >/dev/null 2>&1; then COMPOSE=(podman-compose)
elif podman compose version >/dev/null 2>&1; then  COMPOSE=(podman compose)
elif docker compose version >/dev/null 2>&1; then  COMPOSE=(docker compose)
else die "no compose runtime found"; fi

if [[ -f .env ]]; then
    info "stopping containers..."
    "${COMPOSE[@]}" --env-file .env down
else
    info ".env not found, attempting raw container cleanup..."
    podman rm -f triton-licenseserver triton-license-db 2>/dev/null || true
fi

if [[ $PURGE -eq 1 ]]; then
    info "DESTRUCTIVE: removing license DB volume..."
    read -r -p "  Are you sure? Type 'yes' to confirm: " CONFIRM
    [[ "$CONFIRM" == "yes" ]] || die "aborted"
    podman volume rm -f triton-license-db-data 2>/dev/null \
        || docker volume rm -f triton-license-db-data 2>/dev/null \
        || true
    info "  DB volume removed"
    info "  .env and signing key still on disk at $SCRIPT_DIR/.env — delete manually if desired"
else
    info "DB volume retained (run with --purge-data to delete)"
fi

info "uninstall complete"
