param(
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version = '1.1.1',
    [ValidateNotNullOrEmpty()][string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'),
    [string]$YafsDirectory = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    # Package an existing YAFS release only. Compilation belongs to the YAFS repo.
    if ([string]::IsNullOrWhiteSpace($YafsDirectory)) {
        Write-Output 'Packaging CopyUSB Core (without YAFS).'
    }
    else {
        if (-not (Test-Path -LiteralPath $YafsDirectory -PathType Container)) { throw "YAFS release directory not found: $YafsDirectory. Build it separately in the YAFS project first." }
        Write-Output "Packaging CopyUSB with existing YAFS release: $YafsDirectory"
    }
    & (Join-Path $PSScriptRoot 'Build-Distribution.ps1') -Version $Version -OutputDirectory $OutputDirectory -YafsDirectory $YafsDirectory
}
catch { Write-Error "Package build failed: $($_.Exception.Message)" -ErrorAction Continue; exit 1 }
