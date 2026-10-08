<#
.SYNOPSIS
  Create (or refresh) the local "fake VPS" as a dedicated WSL2 distro named fake-vps.
  Use this when Multipass/Hyper-V networking doesn't work (common on managed laptops).

.DESCRIPTION
  - installs a SEPARATE Ubuntu 24.04 distro "fake-vps" (your existing distros are untouched)
  - enables systemd, makes root the default user
  - exports a "clean" snapshot before anything else (restore with wsl-reset.ps1)
  - copies this repo to /opt/infra inside the distro (re-run to sync your edits)
  - writes inventory/local.env with DOMAIN=<wsl-ip>.sslip.io

  Notes:
  - All WSL2 distros share ONE network stack. Quit Docker Desktop while testing so two
    Docker engines don't fight over ports/iptables, and don't run anything on 80/443 in
    your other distros.
  - WSL stops idle distros: keep a `wsl -d fake-vps` window open while you test.

.EXAMPLE
  .\local\wsl-up.ps1
#>
param(
    [string]$Name = 'fake-vps',
    [string]$Dir = "$env:LOCALAPPDATA\fake-vps",
    # e.g. 127-0-0-1.sslip.io when Docker Desktop publishes the ports (existing distro)
    [string]$Domain = ''
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

function Get-Distros { (wsl.exe -l -q) -replace "`0", '' | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() } }
function In-Vps([string]$cmd) {
    wsl.exe -d $Name -u root -- bash -lc $cmd
    if ($LASTEXITCODE -ne 0) { throw "command failed in ${Name}: $cmd" }
}

New-Item -ItemType Directory -Force $Dir | Out-Null

if ((Get-Distros) -notcontains $Name) {
    Write-Host "==> installing Ubuntu 24.04 as WSL distro '$Name' (separate from your other distros)"
    wsl.exe --install Ubuntu-24.04 --name $Name --location "$Dir\disk" --no-launch
    if ($LASTEXITCODE -ne 0) { throw "wsl --install failed" }

    Write-Host "==> enabling systemd, default user root"
    In-Vps "printf '[boot]\nsystemd=true\n\n[user]\ndefault=root\n\n[interop]\nappendWindowsPath=false\n' > /etc/wsl.conf"
    wsl.exe --terminate $Name | Out-Null

    Write-Host "==> taking 'clean' snapshot -> $Dir\clean.tar  (restore with .\local\wsl-reset.ps1)"
    wsl.exe --export $Name "$Dir\clean.tar"
    if ($LASTEXITCODE -ne 0) { throw "wsl --export failed" }
}

# Start it and wait for systemd.
In-Vps "systemctl is-system-running --wait >/dev/null 2>&1 || true; echo booted"

$ip = (wsl.exe -d $Name -u root -- hostname -I).Trim().Split(' ')[0]
if (-not $ip) { throw "could not determine the WSL IP" }
$domain = if ($Domain) { $Domain } else { ($ip -replace '\.', '-') + '.sslip.io' }

$inv = Join-Path $repo 'inventory\local.env'
if (-not (Test-Path $inv)) { Copy-Item (Join-Path $repo 'inventory\local.env.example') $inv }
# LF + no BOM so bash can source it.
$text = [IO.File]::ReadAllText($inv) -replace "`r`n", "`n"
$text = [regex]::Replace($text, '(?m)^DOMAIN=.*$', "DOMAIN=$domain")
[IO.File]::WriteAllText($inv, $text, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "==> syncing repo -> ${Name}:/opt/infra"
$src = (wsl.exe -d $Name -u root -- wslpath -a "$repo").Trim()
In-Vps "mkdir -p /opt/infra && find /opt/infra -mindepth 1 -delete && tar -C '$src' --exclude=.git -cf - . | tar -C /opt/infra -xf - && find /opt/infra -name '*.sh' -exec sed -i 's/\r$//' {} + && echo synced"

Write-Host ""
Write-Host "WSL ip:  $ip"
Write-Host "DOMAIN:  $domain   (written to inventory\local.env)"
Write-Host ""
Write-Host "Next (keep this shell open while testing - WSL stops idle distros):"
Write-Host "  wsl -d $Name"
if ($Name -eq 'fake-vps') {
    Write-Host "  bash /opt/infra/local/simulate-existing.sh        # pretend other apps already live here"
} else {
    Write-Host "  sudo bash /opt/infra/local/verify-isolation.sh --record   # snapshot YOUR existing containers first"
}
Write-Host "  bash /opt/infra/bootstrap/install.sh /opt/infra/inventory/local.env"
Write-Host "  sudo -u deploy infra platform up"
Write-Host "  sudo -u deploy bash /opt/infra/local/smoke-test.sh"
Write-Host "  bash /opt/infra/local/verify-isolation.sh"
Write-Host ""
Write-Host "Browser: https://traefik.$domain  (self-signed - accept the warning; admin/admin)"
Write-Host "After editing files on Windows, re-run this script to sync them into /opt/infra."
