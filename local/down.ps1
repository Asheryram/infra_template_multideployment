<#
.SYNOPSIS
  Delete the fake VPS entirely (VM, disk and snapshots). Your repo files are untouched.
#>
param([string]$Name = 'fake-vps')
$ErrorActionPreference = 'Stop'

$answer = Read-Host "Delete VM '$Name' and all its data? (yes/no)"
if ($answer -ne 'yes') { Write-Host 'aborted'; exit 0 }
multipass delete $Name --purge
Write-Host "deleted $Name"
