#!/usr/bin/env bash
# uninstall.sh — stop and remove Manage Server containers.
#
# By default, KEEPS the PostgreSQL volume (scan history, hosts, users)
# and the installer directory (preserves .env secrets for reinstall).
# Pass --purge-data to delete volumes + installer directory — irreversible.
#
# Supported: Linux (amd64/arm64), macOS (Intel/Apple Silicon).
# For Windows use uninstall.ps1 instead.
#
# Usage:
#   Linux:  sudo bash uninstall.sh             # stop + remove containers, keep DB + .env
#   Linux:  sudo bash uninstall.sh --purge-data  # also delete DB, volumes, and installer dir
#   macOS:  bash uninstall.sh [--purge-data]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "$SCRIPT_DIR"

info() { printf '[manage-server] %s\n' "$*"; }
die()  { printf '[manage-server] error: %s\n' "$*" >&2; exit 1; }

OS=$(uname -s)

# Docker/Podman Desktop on macOS runs rootless; only Linux needs root.
[[ "$OS" != "Linux" || $EUID -eq 0 ]] || die "must run as root (on Linux use: sudo bash uninstall.sh)"

PURGE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge-data) PURGE=1; shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# //;s/^#//'; exit 0 ;;
        *) die "unknown flag: $1" ;;
    esac
done

if command -v podman-compose >/dev/null 2>&1; then COMPOSE=(podman-compose); RUNTIME=podman
elif podman compose version >/dev/null 2>&1; then  COMPOSE=(podman compose); RUNTIME=podman
elif docker compose version >/dev/null 2>&1; then  COMPOSE=(docker compose); RUNTIME=docker
else die "no compose runtime found"; fi

if [[ -f .env ]]; then
    info "stopping containers..."
    "${COMPOSE[@]}" --env-file .env down
else
    info ".env not found, attempting raw container cleanup..."
    "$RUNTIME" rm -f triton-manageserver triton-manage-db 2>/dev/null || true
fi

if [[ $PURGE -eq 1 ]]; then
    info "DESTRUCTIVE: removing manage server volumes..."
    info "  this deletes: scan history, hosts, users, worker binaries"
    for vol in triton-manage-db-data triton-manage-bins; do
        "$RUNTIME" volume rm -f "$vol" 2>/dev/null || true
    done
    info "  volumes removed"
    info "  removing installer directory $SCRIPT_DIR..."
    rm -rf "$SCRIPT_DIR"
    info "  installer directory removed"
else
    info "DB + bins volumes retained (run with --purge-data to delete)"
    info ".env preserved at $SCRIPT_DIR/.env — secrets reused on reinstall"
fi

info "uninstall complete"
