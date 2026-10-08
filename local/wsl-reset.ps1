<#
.SYNOPSIS
  Roll the WSL fake VPS back to fresh Ubuntu (the "clean" snapshot taken by wsl-up.ps1),
  then re-sync the repo. Use it to prove bootstrap works from scratch.
#>
param(
    [string]$Name = 'fake-vps',
    [string]$Dir = "$env:LOCALAPPDATA\fake-vps"
)
$ErrorActionPreference = 'Stop'

# Safety: only ever reset the throwaway distro created by wsl-up.ps1 - never your own.
if ($Name -ne 'fake-vps' -or -not (Test-Path "$Dir\clean.tar")) {
    throw "refusing: '$Name' is not the throwaway fake-vps distro created by wsl-up.ps1"
}
wsl.exe --terminate $Name | Out-Null
wsl.exe --unregister $Name
if ($LASTEXITCODE -ne 0) { throw "unregister failed" }
Remove-Item -Recurse -Force "$Dir\disk" -ErrorAction SilentlyContinue
wsl.exe --import $Name "$Dir\disk" "$Dir\clean.tar"
if ($LASTEXITCODE -ne 0) { throw "import failed" }
& "$PSScriptRoot\wsl-up.ps1" -Name $Name -Dir $Dir
