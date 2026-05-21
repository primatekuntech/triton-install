#Requires -Version 5.1
# install.ps1 — Triton Manage Server installer for Windows.
#
# Idempotent. Generates secrets on first run, reuses .env afterwards.
# Container-based via Docker Desktop or Podman Desktop (auto-detected).
# Requires Docker Desktop in Linux container mode (the default).
#
# Usage:
#   .\install.ps1
#
# Parameters (all optional):
#   -GatewayHostname HOST    Agent mTLS hostname (defaults to current FQDN).
#   -ManageHostIP IP         Host LAN IP — used for "+ This machine".
#   -Image TAG               Pin a specific manage-server image tag.
#   -NoTls                   Skip the TLS-required sanity check (dev).
param(
    [string]$GatewayHostname = '',
    [string]$ManageHostIP    = '',
    [string]$Image           = '',
    [switch]$NoTls
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

function Write-Info([string]$msg) { Write-Host "[manage-server] $msg" }
function Write-Die([string]$msg)  { Write-Error "[manage-server] error: $msg"; exit 1 }

# ── architecture detection ───────────────────────────────────────────────
$cpuArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
$arch = switch ($cpuArch.ToString()) {
    'X64'   { 'amd64' }
    'Arm64' { 'arm64' }
    default { Write-Die "unsupported architecture: $cpuArch (supported: X64, Arm64)"; 'unknown' }
}
Write-Info "architecture: windows/$arch"

# ── runtime detection ────────────────────────────────────────────────────
$composeCmd = $null
$runtime    = $null

if (Get-Command docker -ErrorAction SilentlyContinue) {
    & docker compose version 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $composeCmd = @('docker','compose'); $runtime = 'docker' }
}
if (-not $composeCmd -and (Get-Command podman -ErrorAction SilentlyContinue)) {
    & podman compose version 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $composeCmd = @('podman','compose'); $runtime = 'podman' }
}
if (-not $composeCmd) {
    Write-Die "no compose runtime found. Install Docker Desktop or Podman Desktop."
}
Write-Info "using runtime: $runtime"

# ── random secret generation ─────────────────────────────────────────────
function New-RandomHex([int]$byteCount) {
    $buf = [byte[]]::new($byteCount)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buf)
    return ($buf | ForEach-Object { $_.ToString('x2') }) -join ''
}

# ── .env bootstrap ───────────────────────────────────────────────────────
$envFile = Join-Path $ScriptDir '.env'

if (-not (Test-Path $envFile)) {
    Write-Info "writing .env from env.template"
    $template = Join-Path $ScriptDir 'env.template'
    if (-not (Test-Path $template)) { Write-Die "env.template not found in $ScriptDir" }
    Copy-Item $template $envFile

    $pgPass    = New-RandomHex 24
    $jwtKey    = New-RandomHex 32
    $workerKey = New-RandomHex 16
    $vaultKey  = New-RandomHex 32

    # Read-modify-write in one pass so line endings are preserved.
    $content = [System.IO.File]::ReadAllText($envFile)
    $content = $content -replace '(?m)^POSTGRES_PASSWORD=.*',             "POSTGRES_PASSWORD=$pgPass"
    $content = $content -replace '(?m)^TRITON_MANAGE_JWT_SIGNING_KEY=.*', "TRITON_MANAGE_JWT_SIGNING_KEY=$jwtKey"
    $content = $content -replace '(?m)^TRITON_MANAGE_WORKER_KEY=.*',      "TRITON_MANAGE_WORKER_KEY=$workerKey"
    $content = $content -replace '(?m)^TRITON_VAULT_KEY=.*',              "TRITON_VAULT_KEY=$vaultKey"
    [System.IO.File]::WriteAllText($envFile, $content)
    Write-Info "vault key generated (PostgreSQL AES-256-GCM)"

    if ($GatewayHostname) {
        $content = [System.IO.File]::ReadAllText($envFile)
        $content = $content -replace '(?m)^TRITON_MANAGE_GATEWAY_HOSTNAME=.*', "TRITON_MANAGE_GATEWAY_HOSTNAME=$GatewayHostname"
        [System.IO.File]::WriteAllText($envFile, $content)
    }
    if ($ManageHostIP) {
        $content = [System.IO.File]::ReadAllText($envFile)
        $content = $content -replace '(?m)^TRITON_MANAGE_HOST_IP=.*', "TRITON_MANAGE_HOST_IP=$ManageHostIP"
        [System.IO.File]::WriteAllText($envFile, $content)
    }
    # IMAGE has no placeholder line in env.template — append it directly.
    if ($Image) {
        Add-Content $envFile "`nTRITON_MANAGE_IMAGE=$Image"
    }

    Write-Info ".env created at $envFile"
    Write-Info "  back this up — it contains the JWT signing key, worker key, and vault key"
} else {
    Write-Info "reusing existing .env at $envFile"
}

# ── start ────────────────────────────────────────────────────────────────
Write-Info "starting containers..."
& $composeCmd[0] $composeCmd[1] --env-file $envFile up -d
if ($LASTEXITCODE -ne 0) { Write-Die "compose up failed (exit $LASTEXITCODE)" }

# ── wait for health ──────────────────────────────────────────────────────
$portLine = Get-Content $envFile | Where-Object { $_ -match '^TRITON_MANAGE_HOST_PORT=' } | Select-Object -First 1
$hostPort = if ($portLine) { $portLine -replace '^TRITON_MANAGE_HOST_PORT=', '' } else { '8082' }

Write-Info "waiting for manage server to become healthy on :$hostPort..."
$up = $false
for ($i = 1; $i -le 30; $i++) {
    try {
        $resp = Invoke-WebRequest "http://localhost:$hostPort/" -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
        if ($resp.StatusCode -in @(200, 302)) { $up = $true; break }
    } catch [System.Net.WebException] {
        $code = [int]$_.Exception.Response.StatusCode
        if ($code -in @(200, 302)) { $up = $true; break }
    } catch { <# connection refused — keep polling #> }
    Start-Sleep -Seconds 2
}

if ($up) {
    Write-Info "manage server is up"
} else {
    Write-Info "warning: health check timed out — check logs with: $($composeCmd -join ' ') logs manage-server"
}

Write-Info ""
Write-Info "Installation complete. Next steps:"
Write-Info "  1. Open http://localhost:$hostPort (or your public URL)"
Write-Info "  2. Complete the setup wizard:"
Write-Info "       - Set your manage server name"
Write-Info "       - Enter your Triton licence server URL and licence ID"
Write-Info "       - Or upload an air-gap licence file"
Write-Info "  3. Configure TLS via reverse proxy (see docs)"
Write-Info ""
