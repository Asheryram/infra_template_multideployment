<#
.SYNOPSIS
  Delete the WSL fake VPS distro and its snapshot. Only touches the distro named fake-vps;
  your other WSL distros and the repo files are untouched.
#>
param(
    [string]$Name = 'fake-vps',
    [string]$Dir = "$env:LOCALAPPDATA\fake-vps"
)
$ErrorActionPreference = 'Stop'

# Safety: only ever delete the throwaway distro created by wsl-up.ps1 - never your own.
# (To remove infra from an existing distro, run bootstrap/uninstall.sh inside it instead.)
if ($Name -ne 'fake-vps' -or -not (Test-Path "$Dir\clean.tar")) {
    throw "refusing: '$Name' is not the throwaway fake-vps distro created by wsl-up.ps1"
}

$answer = Read-Host "Delete WSL distro '$Name' and $Dir? (yes/no)"
if ($answer -ne 'yes') { Write-Host 'aborted'; exit 0 }
wsl.exe --terminate $Name | Out-Null
wsl.exe --unregister $Name
Remove-Item -Recurse -Force $Dir -ErrorAction SilentlyContinue
Write-Host "deleted $Name"
