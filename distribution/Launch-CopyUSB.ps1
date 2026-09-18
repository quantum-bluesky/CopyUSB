param([string]$SourceRoot = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    $release = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'current.txt') -Raw).Trim()
    if ($release -notmatch '^[0-9]+\.[0-9]+\.[0-9]+-[a-f0-9]{32}$') { throw 'Invalid installed release.' }
    $app = Join-Path $PSScriptRoot "versions\$release"
    $manifest = Get-Content -LiteralPath (Join-Path $app 'manifest.json') -Raw | ConvertFrom-Json
    Set-Location -LiteralPath $app
    & (Join-Path $app 'CopyUSB-GUI.ps1') -SourceRoot $SourceRoot -CheckAndSort ([bool]$manifest.HasYafs) -LogDir (Join-Path $PSScriptRoot 'logs') -RemountCachePath (Join-Path $PSScriptRoot 'usb_remount_cache.json')
}
catch { Write-Error "Cannot start CopyUSB: $($_.Exception.Message)"; exit 1 }
