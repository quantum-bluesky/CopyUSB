param(
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version = '1.1.0',
    [ValidateSet('x86', 'x64')][string]$Architecture = 'x86',
    [ValidateRange(1, 64)][int]$Jobs = 4
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    $zip = Join-Path $PSScriptRoot "dist\CopyUSB-$Version.zip"
    if (Test-Path -LiteralPath $zip) { throw "Package exists: $zip. Increase -Version for the next release." }
    & (Join-Path $PSScriptRoot 'Build-Yafs.ps1') -Version $Version -Architecture $Architecture -Jobs $Jobs
    & (Join-Path $PSScriptRoot 'Build-Distribution.ps1') -Version $Version -YafsDirectory (Join-Path $PSScriptRoot "dist\yafs\$Version-$Architecture")
}
catch { Write-Error "Full package build failed: $($_.Exception.Message)" -ErrorAction Continue; exit 1 }
