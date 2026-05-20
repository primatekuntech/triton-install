# Triton Manage Server Installer

Production installer for the Triton Manage Server. Container-based (Docker or Podman), idempotent — safe to re-run.

## Install

Your vendor provides a licence bundle — a single file:

```
license.lic   # signed offline licence token
```

The vendor's public key is baked into the image at build time — nothing else to configure.

Point the installer at the bundle:

```bash
curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/get.sh | sudo bash -s -- --license-file /path/to/triton-bundle/license.lic
```

## Setup wizard

After install, open `http://localhost:8082` and complete the wizard:

1. Set your manage server name
2. Create the admin account

## Optional flags

Pass flags after `--`:

```bash
curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/get.sh | sudo bash -s -- --license-file /path/to/license.lic [flags]
```

| Flag | Description |
|------|-------------|
| `--license-file PATH` | Path to `license.lic` from your vendor bundle. **Required.** |
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

## Host-bound licences

Your vendor can issue an offline `.lic` file that is cryptographically bound to a specific host
so it cannot be used on any other machine.

**To get a host-bound licence:**

1. Run the installer on the target server. At the end of the output you will see:
   ```
   [manage-server] ── Host Machine ID ──────────────────────────────────────────────────────
   [manage-server]   Provide this value to your vendor when requesting a host-bound .lic file.
   [manage-server]   Machine ID (SHA-3-256): <64-hex-chars>
   [manage-server] ────────────────────────────────────────────────────────────────────────
   ```
2. Share the 64-character hex value with your vendor.
3. The vendor enters it in the License Portal when generating the offline `.lic` token.
4. Re-run the installer with the new `.lic` file — the Manage Server verifies the binding at every startup.

**The Machine ID is stable.** It is a SHA-3-256 hash of `/etc/machine-id`, which is written once
at OS installation and never changes. Container restarts, image upgrades, and re-running the
installer will always produce the same value.

To retrieve the Machine ID at any time without re-installing, simply re-run the install command:

```bash
curl -fsSL https://raw.githubusercontent.com/primatekuntech/triton-install/main/get.sh | sudo bash -s -- --license-file /path/to/license.lic
```

For air-gapped deployments without host binding the `.lic` file is portable, but anyone who
obtains the file can run a second instance. Host binding removes that risk.

## Requirements

- Linux (amd64 or arm64) or macOS
- Docker or Podman with Compose (auto-installed if missing)
- Port 443 open (HTTPS)
