#Requires -Version 5.1
<#
.SYNOPSIS
    Helper script for running dsi-backup with Podman on Windows Server.

.DESCRIPTION
    Checks that Podman is installed, lists available named volumes so you
    can populate compose.podman.yml, then builds and starts the services.

.PARAMETER Action
    start   - Build images and start all services (default)
    stop    - Stop and remove containers
    restart - Stop then start
    logs    - Tail logs from all services
    volumes - List Podman named volumes (use these in compose.podman.yml)
    status  - Show running container status

.EXAMPLE
    .\setup-podman.ps1 volumes          # See what volumes exist
    .\setup-podman.ps1                  # Start everything
    .\setup-podman.ps1 -Action logs     # Follow logs
#>

param(
    [ValidateSet('start','stop','restart','logs','volumes','status')]
    [string]$Action = 'start'
)

$ComposeFile = Join-Path $PSScriptRoot 'compose.podman.yml'
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Msg) Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "    OK: $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "    WARN: $Msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$Msg) Write-Host "    ERROR: $Msg" -ForegroundColor Red; exit 1 }

# ── Preflight checks ──────────────────────────────────────────────────────────

Write-Step 'Checking Podman installation'

if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
    Write-Fail @'
Podman is not on your PATH.

Install options:
  1. Podman for Windows (recommended):
     https://github.com/containers/podman/releases
     Run the .msi installer, then restart your shell.

  2. Via winget:
     winget install RedHat.Podman

After installing, run:  podman machine init
                        podman machine start
'@
}

$podmanVersion = podman version --format '{{.Client.Version}}' 2>$null
Write-Ok "Podman $podmanVersion found"

# Check the Podman machine is running (Windows-specific)
$machineState = podman machine list --format '{{.Running}}' 2>$null | Select-Object -First 1
if ($machineState -ne 'true') {
    Write-Step 'Podman machine is not running — starting it'
    podman machine start
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Failed to start Podman machine' }
    Write-Ok 'Podman machine started'
}

# ── Volume listing (help the user configure compose.podman.yml) ───────────────

if ($Action -eq 'volumes') {
    Write-Step 'Podman named volumes on this machine'
    $volumes = podman volume ls --format '{{.Name}}'
    if (-not $volumes) {
        Write-Warn 'No named volumes found. Start your application containers first.'
    } else {
        Write-Host ''
        Write-Host '  Volume name               Add to compose.podman.yml as:' -ForegroundColor White
        Write-Host '  ─────────────────────────────────────────────────────────────'
        foreach ($vol in $volumes) {
            $label = $vol -replace '[^a-zA-Z0-9]', '-'
            Write-Host ("  {0,-25} - {1}:/volumes/{2}:ro" -f $vol, $vol, $label)
        }
        Write-Host ''
        Write-Host '  Then add matching entries under the top-level  volumes:  key:' -ForegroundColor Gray
        foreach ($vol in $volumes) {
            Write-Host ("  {0}:" -f $vol) -ForegroundColor Gray
            Write-Host '    external: true' -ForegroundColor Gray
        }
    }
    exit 0
}

# ── Compose file check ────────────────────────────────────────────────────────

Write-Step 'Checking compose.podman.yml'

if (-not (Test-Path $ComposeFile)) {
    Write-Fail "compose.podman.yml not found at: $ComposeFile"
}

# Warn if the user still has the placeholder volume
$content = Get-Content $ComposeFile -Raw
if ($content -match 'example_volume') {
    Write-Warn "compose.podman.yml still contains the placeholder 'example_volume'."
    Write-Warn "Run  .\setup-podman.ps1 volumes  to see your real volumes, then edit the file."
}

Write-Ok 'compose.podman.yml found'

# ── Detect compose command ────────────────────────────────────────────────────
# Prefer 'podman compose' (Podman 4.0+ built-in); fall back to podman-compose

function Get-ComposeCmd {
    $help = podman compose --help 2>&1
    if ($LASTEXITCODE -eq 0) { return @('podman', 'compose') }

    if (Get-Command podman-compose -ErrorAction SilentlyContinue) {
        return @('podman-compose')
    }

    Write-Fail @'
No compose tool found. Install one:
  podman compose  — built into Podman 4.0+; upgrade Podman.
  podman-compose  — pip install podman-compose
'@
}

$composeCmd = Get-ComposeCmd
$composeBin = $composeCmd[0]
$composeSub = if ($composeCmd.Count -gt 1) { $composeCmd[1] } else { $null }

function Invoke-Compose {
    param([string[]]$Args)
    $fullArgs = @('-f', $ComposeFile) + $Args
    if ($composeSub) { $fullArgs = @($composeSub) + $fullArgs }
    & $composeBin @fullArgs
    if ($LASTEXITCODE -ne 0) { Write-Fail "Compose command failed (exit $LASTEXITCODE)" }
}

# ── Actions ───────────────────────────────────────────────────────────────────

switch ($Action) {

    'start' {
        Write-Step 'Building images'
        Invoke-Compose 'build'

        Write-Step 'Starting services'
        Invoke-Compose 'up', '-d'

        Write-Ok 'Services started'
        Write-Host ''
        Write-Host '  To follow logs:    .\setup-podman.ps1 -Action logs'
        Write-Host '  To check status:   .\setup-podman.ps1 -Action status'
        Write-Host '  To stop:           .\setup-podman.ps1 -Action stop'
    }

    'stop' {
        Write-Step 'Stopping services'
        Invoke-Compose 'down'
        Write-Ok 'Services stopped'
    }

    'restart' {
        Write-Step 'Restarting services'
        Invoke-Compose 'down'
        Invoke-Compose 'up', '-d'
        Write-Ok 'Services restarted'
    }

    'logs' {
        Write-Step 'Tailing logs (Ctrl+C to stop)'
        Invoke-Compose 'logs', '-f'
    }

    'status' {
        Write-Step 'Container status'
        Invoke-Compose 'ps'
    }
}
