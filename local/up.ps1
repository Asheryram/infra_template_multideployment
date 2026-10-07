<#
.SYNOPSIS
  Create (or resume) the local "fake VPS": an Ubuntu VM that behaves like the real server.

.DESCRIPTION
  - launches a Multipass VM sized like a small VPS
  - takes a "clean" snapshot BEFORE bootstrap, so you can prove bootstrap works on a fresh box
  - mounts this repo at /opt/infra (edit on Windows, run in the VM)
  - writes inventory/local.env with DOMAIN=<vm-ip>.sslip.io (and fixes it if the IP changed)

.EXAMPLE
  .\local\up.ps1
  .\local\up.ps1 -Memory 8G -Cpus 4
#>
param(
    [string]$Name = 'fake-vps',
    [int]$Cpus = 2,
    [string]$Memory = '4G',
    [string]$Disk = '30G',
    [string]$Image = '24.04'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

function Get-Vm {
    $list = (multipass list --format json | ConvertFrom-Json).list
    return $list | Where-Object { $_.name -eq $Name }
}

$vm = Get-Vm
if (-not $vm) {
    Write-Host "==> launching $Name ($Cpus CPU, $Memory RAM, $Disk disk, Ubuntu $Image)"
    multipass launch $Image --name $Name --cpus $Cpus --memory $Memory --disk $Disk --cloud-init "$PSScriptRoot\cloud-init.yaml"
    if ($LASTEXITCODE -ne 0) { throw "multipass launch failed" }

    Write-Host "==> taking 'clean' snapshot (restore with .\local\reset.ps1)"
    multipass stop $Name
    multipass snapshot $Name --name clean
    if ($LASTEXITCODE -ne 0) { Write-Warning "snapshot not supported by this Multipass driver - continuing without it" }
    multipass start $Name
}
elseif ($vm.state -ne 'Running') {
    multipass start $Name
}

Write-Host "==> mounting $repo -> ${Name}:/opt/infra"
multipass set local.privileged-mounts=true
$info = (multipass info $Name --format json | ConvertFrom-Json).info.$Name
$mounted = $info.mounts.PSObject.Properties.Name -contains '/opt/infra'
if (-not $mounted) {
    multipass mount "$repo" "${Name}:/opt/infra"
    if ($LASTEXITCODE -ne 0) { throw "multipass mount failed" }
}

$ip = $info.ipv4[0]
$domain = ($ip -replace '\.', '-') + '.sslip.io'
$inv = Join-Path $repo 'inventory\local.env'
if (-not (Test-Path $inv)) {
    Copy-Item (Join-Path $repo 'inventory\local.env.example') $inv
}
# Write with LF and no BOM - bash must be able to source it.
$text = [IO.File]::ReadAllText($inv) -replace "`r`n", "`n"
$text = [regex]::Replace($text, '(?m)^DOMAIN=.*$', "DOMAIN=$domain")
[IO.File]::WriteAllText($inv, $text, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "VM ip:   $ip"
Write-Host "DOMAIN:  $domain   (written to inventory\local.env)"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  multipass shell $Name"
Write-Host "  sudo bash /opt/infra/bootstrap/install.sh /opt/infra/inventory/local.env"
Write-Host "  sudo -u deploy infra platform up"
Write-Host "  sudo -u deploy bash /opt/infra/local/smoke-test.sh"
Write-Host ""
Write-Host "Then open https://traefik.$domain  (self-signed: accept the browser warning)"
Write-Host "If the VM IP changes after a host reboot, re-run this script, then in the VM:"
Write-Host "  sudo bash /opt/infra/bootstrap/install.sh /opt/infra/inventory/local.env 50; sudo -u deploy infra platform up"
