# Triton Manage Server Installer

Production installer for the Triton Manage Server. Container-based (Docker or Podman), idempotent — safe to re-run.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/manage-server/install.sh | sudo bash -s -- \
  --license-server-pubkey <HEX> \
  --license-server-url    https://license.yourvendor.com \
  --gateway-hostname      manage.customer.com
```

## Flags

| Flag | Description |
|------|-------------|
| `--license-server-pubkey` | Ed25519 public key (64 hex chars). **Required.** |
| `--license-server-url` | URL of your License Server. |
| `--license-token` | Pre-fill activation token (else use setup wizard). |
| `--gateway-hostname` | Agent mTLS hostname (defaults to current FQDN). |
| `--manage-host-ip` | Host LAN IP for "+ This machine". |
| `--image` | Pin a specific image tag. |
| `--no-tls` | Skip TLS check (dev only). |

## Other commands

```bash
# Upgrade
sudo bash manage-server/upgrade.sh

# Uninstall
sudo bash manage-server/uninstall.sh
```

## Requirements

- Linux (amd64 or arm64)
- Docker or Podman
- Port 443 open (HTTPS)
