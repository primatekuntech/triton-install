#!/usr/bin/env bash
# uninstall.sh — stop and remove Manage Server containers.
#
# By default, KEEPS the PostgreSQL volume (scan history, hosts, users).
# Pass --purge-data to delete the volumes as well — irreversible.
#
# Usage:
#   sudo bash uninstall.sh                       # stop + remove containers, keep DB
#   sudo bash uninstall.sh --purge-data          # also delete DB + binaries volume (interactive)
#   sudo bash uninstall.sh --purge-data --yes    # non-interactive purge (e.g. curl | bash)
#   --version                                    Print script version and exit.
SCRIPT_VERSION="2026-05-21.6"
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "$SCRIPT_DIR"

info() { printf '[manage-server] %s\n' "$*"; }
die()  { printf '[manage-server] error: %s\n' "$*" >&2; exit 1; }

info "uninstall.sh version $SCRIPT_VERSION"

[[ $EUID -eq 0 ]] || die "must run as root"

PURGE=0
YES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge-data) PURGE=1; shift ;;
        --yes)        YES=1;   shift ;;
        --version) echo "uninstall.sh version $SCRIPT_VERSION"; exit 0 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# //;s/^#//'; exit 0 ;;
        *) die "unknown flag: $1" ;;
    esac
done

RUNTIME=""
if command -v podman-compose >/dev/null 2>&1; then COMPOSE=(podman-compose); RUNTIME=podman
elif podman compose version >/dev/null 2>&1; then  COMPOSE=(podman compose);  RUNTIME=podman
elif docker compose version >/dev/null 2>&1; then  COMPOSE=(docker compose);  RUNTIME=docker
else die "no compose runtime found"; fi

if [[ -f .env ]]; then
    info "stopping containers..."
    "${COMPOSE[@]}" --env-file .env down
else
    info ".env not found, attempting raw container cleanup..."
    "${RUNTIME}" rm -f triton-manageserver triton-manage-db 2>/dev/null || true
fi

if [[ $PURGE -eq 1 ]]; then
    info "DESTRUCTIVE: removing manage server volumes..."
    info "  this deletes: scan history, hosts, users, worker binaries"
    if [[ $YES -eq 1 || ! -t 0 ]]; then
        info "  non-interactive mode, proceeding automatically"
    else
        read -r -p "  Are you sure? Type 'yes' to confirm: " CONFIRM
        [[ "$CONFIRM" == "yes" ]] || die "aborted"
    fi
    for vol in triton-manage-db-data triton-manage-bins; do
        podman volume rm -f "$vol" 2>/dev/null \
            || docker volume rm -f "$vol" 2>/dev/null \
            || true
    done
    info "  volumes removed"
    info "  .env still on disk at $SCRIPT_DIR/.env — delete manually if desired"
else
    info "DB + bins volumes retained (run with --purge-data to delete)"
fi

info "uninstall complete"
