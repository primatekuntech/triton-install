# Triton Manage Server Installer

Production installer for the Triton Manage Server. Container-based (Docker or Podman), idempotent — safe to re-run.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/get.sh | sudo bash
```

That's it. The setup wizard walks you through the rest.

## Setup wizard

After install, open `http://localhost:8082` and complete the wizard:

1. Set your manage server name
2. Enter your Triton licence server URL and licence ID — or upload an air-gap licence file
3. Create the admin account

## Optional flags

Pass flags after `--`:

```bash
curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/get.sh | sudo bash -s -- [flags]
```

| Flag | Description |
|------|-------------|
| `--license-server-url URL` | Vendor's License Server URL. Public key is fetched automatically. |
| `--gateway-hostname HOST` | Agent mTLS hostname (defaults to current FQDN). |
| `--manage-host-ip IP` | Host LAN IP for "+ This machine" auto-registration. |
| `--port PORT` | Host port for the web UI (default: `8082`). |
| `--image TAG` | Pin a specific image tag (e.g. `1.0.0-rc.2`). |
| `--no-tls` | Skip TLS sanity check (dev only). |

## Upgrade

Pull the latest image and restart (keeps all data, runs DB migrations automatically):

```bash
curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/get.sh | sudo bash -s -- --upgrade
```

Pin a specific version:

```bash
curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/get.sh | sudo bash -s -- --upgrade --image ghcr.io/primatekuntech/triton-manage-server:1.2.0
```

## Uninstall

Stop containers and remove them, but keep all data (PostgreSQL volume, credentials vault):

```bash
curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/get.sh | sudo bash -s -- --uninstall
```

Also delete all data (irreversible):

```bash
curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/get.sh | sudo bash -s -- --uninstall --purge-data
```

## Requirements

- Linux (amd64 or arm64) or macOS
- Docker or Podman with Compose (auto-installed if missing)
- Port 443 open (HTTPS)
