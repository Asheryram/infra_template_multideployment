<#
.SYNOPSIS
  Roll the fake VPS back to the fresh-Ubuntu "clean" snapshot (before bootstrap).
  Use it to prove bootstrap works from scratch, or after breaking things on purpose.
#>
param([string]$Name = 'fake-vps')
$ErrorActionPreference = 'Stop'

multipass stop $Name
multipass restore "$Name.clean" --destructive
if ($LASTEXITCODE -ne 0) { throw "restore failed (does the 'clean' snapshot exist? multipass list --snapshots)" }
multipass start $Name
& "$PSScriptRoot\up.ps1" -Name $Name
