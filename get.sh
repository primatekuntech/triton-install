#!/usr/bin/env bash
# get.sh — One-line bootstrapper for Triton Manage Server.
#
# Downloads the installer to /opt/triton-manage-server (Linux) or
# ~/.local/share/triton-manage-server (macOS), installs Podman if needed,
# then hands off to install.sh.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/get.sh | sudo bash
#
# Pass flags through to install.sh:
#   curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/get.sh \
#     | sudo bash -s -- --gateway-hostname manage.example.com --manage-host-ip 10.0.0.5
#
# Upgrade (pull latest image, run DB migrations, keep data):
#   curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/get.sh \
#     | sudo bash -s -- --upgrade
#
# Upgrade to a specific image tag:
#   curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/get.sh \
#     | sudo bash -s -- --upgrade --image ghcr.io/primatekuntech/triton-manage-server:1.2.0
#
# Uninstall (stop containers, keep data):
#   curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/get.sh \
#     | sudo bash -s -- --uninstall
#
# Uninstall and delete all data (irreversible):
#   curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/get.sh \
#     | sudo bash -s -- --uninstall --purge-data

set -euo pipefail

REPO_BASE="https://raw.githubusercontent.com/primatekuntech/triton-install/main/manage-server"
INSTALLER_FILES=(install.sh upgrade.sh uninstall.sh compose.yaml env.template)

# ── colour helpers ────────────────────────────────────────────────────────
BOLD='\033[1m'; CYAN='\033[1;96m'; GREEN='\033[1;32m'
YELLOW='\033[1;33m'; RED='\033[1;91m'; RESET='\033[0m'
info()    { printf "${CYAN}  •${RESET} %s\n" "$*"; }
ok()      { printf "${GREEN}  ✓${RESET} %s\n" "$*"; }
warn()    { printf "${YELLOW}  !${RESET} %s\n" "$*"; }
die()     { printf "\n${RED}  ✗ error:${RESET} %s\n\n" "$*" >&2; exit 1; }
banner()  { printf "\n${BOLD}%s${RESET}\n\n" "$*"; }

# ── arg pre-scan (before any output) ─────────────────────────────────────
UNINSTALL=0
UPGRADE=0
PASSTHROUGH=()
for arg in "$@"; do
    case "$arg" in
        --uninstall) UNINSTALL=1 ;;
        --upgrade)   UPGRADE=1 ;;
        *)           PASSTHROUGH+=("$arg") ;;
    esac
done

# ── OS detection ──────────────────────────────────────────────────────────
case "$(uname -s)" in
    Linux)  PLATFORM=linux ;;
    Darwin) PLATFORM=macos ;;
    *)      die "unsupported OS: $(uname -s)" ;;
esac

# ── install directory ─────────────────────────────────────────────────────
if [[ "$PLATFORM" == "linux" ]]; then
    INSTALL_DIR="/opt/triton-manage-server"
else
    INSTALL_DIR="${HOME}/.local/share/triton-manage-server"
fi

# ── uninstall shortcut ────────────────────────────────────────────────────
if [[ $UNINSTALL -eq 1 ]]; then
    banner "▶  Triton Manage Server — Uninstaller"
    info "platform: $PLATFORM"
    if [[ "$PLATFORM" == "linux" && $EUID -ne 0 ]]; then
        die "run as root on Linux:\n\n    curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/get.sh | sudo bash -s -- --uninstall"
    fi
    [[ -f "${INSTALL_DIR}/uninstall.sh" ]] \
        || die "Triton Manage Server does not appear to be installed (${INSTALL_DIR} not found)"
    exec bash "${INSTALL_DIR}/uninstall.sh" "${PASSTHROUGH[@]}"
fi

# ── upgrade shortcut ──────────────────────────────────────────────────────
if [[ $UPGRADE -eq 1 ]]; then
    banner "▶  Triton Manage Server — Upgrade"
    info "platform: $PLATFORM"
    if [[ "$PLATFORM" == "linux" && $EUID -ne 0 ]]; then
        die "run as root on Linux:\n\n    curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/get.sh | sudo bash -s -- --upgrade"
    fi
    [[ -d "$INSTALL_DIR" ]] \
        || die "Triton Manage Server does not appear to be installed (${INSTALL_DIR} not found)"
    info "refreshing installer files..."
    for f in "${INSTALLER_FILES[@]}"; do
        curl -fsSL "${REPO_BASE}/${f}" -o "${INSTALL_DIR}/${f}"
    done
    chmod +x "${INSTALL_DIR}/install.sh" "${INSTALL_DIR}/upgrade.sh" "${INSTALL_DIR}/uninstall.sh"
    ok "installer files refreshed"
    echo ""
    exec bash "${INSTALL_DIR}/upgrade.sh" "${PASSTHROUGH[@]}"
fi

banner "▶  Triton Manage Server — Installer"
info "platform: $PLATFORM"

# ── root check ────────────────────────────────────────────────────────────
if [[ "$PLATFORM" == "linux" && $EUID -ne 0 ]]; then
    die "run as root on Linux:\n\n    curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/get.sh | sudo bash"
fi

# ── runtime detection ─────────────────────────────────────────────────────
has_podman()  { command -v podman >/dev/null 2>&1; }
has_docker()  { command -v docker >/dev/null 2>&1; }
has_compose() {
    command -v podman-compose >/dev/null 2>&1 ||
    { has_podman && podman compose version >/dev/null 2>&1; } ||
    { has_docker && docker compose version >/dev/null 2>&1; }
}

# ── podman installation ───────────────────────────────────────────────────
install_podman_compose_pip() {
    if command -v pip3 >/dev/null 2>&1; then
        warn "podman-compose not in package manager — trying pip3..."
        pip3 install --quiet podman-compose
        ok "podman-compose installed via pip3"
    else
        die "podman-compose not available. Install it manually: pip3 install podman-compose"
    fi
}

install_podman_linux() {
    if command -v apt-get >/dev/null 2>&1; then
        info "installing podman via apt..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y podman
        apt-get install -y podman-compose 2>/dev/null || install_podman_compose_pip

    elif command -v dnf >/dev/null 2>&1; then
        info "installing podman via dnf..."
        dnf install -y podman
        dnf install -y podman-compose 2>/dev/null || install_podman_compose_pip

    elif command -v yum >/dev/null 2>&1; then
        info "installing podman via yum..."
        yum install -y podman
        yum install -y podman-compose 2>/dev/null || install_podman_compose_pip

    elif command -v zypper >/dev/null 2>&1; then
        info "installing podman via zypper..."
        zypper --non-interactive install podman
        zypper --non-interactive install podman-compose 2>/dev/null || install_podman_compose_pip

    elif command -v pacman >/dev/null 2>&1; then
        info "installing podman via pacman..."
        pacman -Sy --noconfirm podman
        pacman -S --noconfirm podman-compose 2>/dev/null || install_podman_compose_pip

    else
        die "no supported package manager (apt/dnf/yum/zypper/pacman).\nInstall podman manually: https://podman.io/docs/installation"
    fi
}

install_podman_macos() {
    if ! command -v brew >/dev/null 2>&1; then
        die "Homebrew not found. Install it first:\n\n    /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    fi
    info "installing podman via Homebrew..."
    brew install podman
    brew install podman-compose 2>/dev/null || install_podman_compose_pip

    info "initializing podman machine..."
    if podman machine list 2>/dev/null | grep -q "Currently running"; then
        ok "podman machine already running"
    else
        podman machine init --now 2>/dev/null || {
            # machine already exists — just start it
            podman machine start 2>/dev/null || true
        }
        ok "podman machine started"
    fi
}

# ── check / install runtime ───────────────────────────────────────────────
if has_podman && has_compose; then
    ok "podman is already installed ($(podman --version))"
elif has_docker && has_compose; then
    ok "docker is already installed — using docker compose"
else
    if has_podman; then
        warn "podman found but no compose runtime — installing podman-compose..."
        install_podman_compose_pip
    else
        info "no container runtime found — installing Podman..."
        if [[ "$PLATFORM" == "linux" ]]; then
            install_podman_linux
        else
            install_podman_macos
        fi
        ok "Podman installed ($(podman --version))"
    fi
fi

has_compose || die "no compose runtime available after installation. Report this at https://github.com/primatekuntech/triton-install/issues"

# ── download installer files ──────────────────────────────────────────────
info "downloading manage-server installer to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"

for f in "${INSTALLER_FILES[@]}"; do
    curl -fsSL "${REPO_BASE}/${f}" -o "${INSTALL_DIR}/${f}"
done
chmod +x "${INSTALL_DIR}/install.sh" "${INSTALL_DIR}/upgrade.sh" "${INSTALL_DIR}/uninstall.sh"
ok "installer files saved to ${INSTALL_DIR}"

# ── hand off ─────────────────────────────────────────────────────────────
echo ""
exec bash "${INSTALL_DIR}/install.sh" "${PASSTHROUGH[@]}"
