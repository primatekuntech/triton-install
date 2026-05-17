# Triton Manage Server Installer

Production installer for the Triton Manage Server. Container-based (Docker or Podman), idempotent — safe to re-run.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/manage-server/install.sh | sudo bash
```

That's it. The setup wizard walks you through the rest.

## Setup wizard

After install, open `http://localhost:8082` and complete the wizard:

1. Set your manage server name
2. Enter your Triton licence server URL and licence ID — or upload an air-gap licence file
3. Create the admin account

## Optional flags

```bash
sudo bash install.sh [flags]
```

| Flag | Description |
|------|-------------|
| `--gateway-hostname HOST` | Agent mTLS hostname (defaults to current FQDN). |
| `--manage-host-ip IP` | Host LAN IP for "+ This machine" auto-registration. |
| `--image TAG` | Pin a specific image tag (e.g. `1.0.0-rc.2`). |
| `--no-tls` | Skip TLS sanity check (dev only). |

## Other commands

```bash
# Upgrade to latest image
sudo bash manage-server/upgrade.sh

# Uninstall
sudo bash manage-server/uninstall.sh
```

## Requirements

- Linux (amd64 or arm64)
- Docker or Podman with Compose
- Port 443 open (HTTPS)
