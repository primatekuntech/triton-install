#Requires -Version 5.1
# uninstall.ps1 — stop and remove Manage Server containers on Windows.
#
# By default, KEEPS the PostgreSQL volume (scan history, hosts, users)
# and the installer directory (preserves .env secrets for reinstall).
# Pass -PurgeData to delete volumes + installer directory — irreversible.
#
# Usage:
#   .\uninstall.ps1              # stop + remove containers, keep DB + .env
#   .\uninstall.ps1 -PurgeData   # also delete DB, volumes, and installer dir
param(
    [switch]$PurgeData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

function Write-Info([string]$msg) { Write-Host "[manage-server] $msg" }
function Write-Die([string]$msg)  { Write-Error "[manage-server] error: $msg"; exit 1 }

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
if (-not $composeCmd) { Write-Die "no compose runtime found" }

# ── stop containers ──────────────────────────────────────────────────────
$envFile = Join-Path $ScriptDir '.env'
if (Test-Path $envFile) {
    Write-Info "stopping containers..."
    & $composeCmd[0] $composeCmd[1] --env-file $envFile down
} else {
    Write-Info ".env not found, attempting raw container cleanup..."
    $ErrorActionPreference = 'Continue'
    & $runtime rm -f triton-manageserver triton-manage-db 2>$null
    $ErrorActionPreference = 'Stop'
}

# ── purge ────────────────────────────────────────────────────────────────
if ($PurgeData) {
    Write-Info "DESTRUCTIVE: removing manage server volumes..."
    Write-Info "  this deletes: scan history, hosts, users, worker binaries"
    $ErrorActionPreference = 'Continue'
    foreach ($vol in @('triton-manage-db-data', 'triton-manage-bins')) {
        & $runtime volume rm -f $vol 2>$null
    }
    $ErrorActionPreference = 'Stop'
    Write-Info "  volumes removed"
    Write-Info "  removing installer directory $ScriptDir..."
    Remove-Item -Recurse -Force $ScriptDir
    Write-Info "  installer directory removed"
} else {
    Write-Info "DB + bins volumes retained (run with -PurgeData to delete)"
    Write-Info ".env preserved at $envFile — secrets reused on reinstall"
}

Write-Info "uninstall complete"
