param([ValidateNotNullOrEmpty()][string]$WorkDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) ('dist\test-' + [guid]::NewGuid().ToString('N'))))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Assert-True([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Install-Package([string]$Package, [string]$Target, [bool]$Success) {
    & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Package 'Install-CopyUSB.ps1') -InstallDirectory $Target -NoShortcuts -NoContextMenu
    Assert-True (($LASTEXITCODE -eq 0) -eq $Success) 'Unexpected installer result'
}
try {
    $target = Join-Path $WorkDirectory 'installed with spaces'
    & (Join-Path $repo 'Build-Distribution.ps1') -Version 1.0.0 -OutputDirectory $WorkDirectory
    $package = Join-Path $WorkDirectory 'package'
    Expand-Archive -LiteralPath (Join-Path $WorkDirectory 'CopyUSB-1.0.0.zip') -DestinationPath $package
    $savedLocal = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = Join-Path $WorkDirectory 'fake local appdata'
        New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
        # A file named Programs makes the old install location unusable.
        Set-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'Programs') -Value 'blocked'
        & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package 'Install-CopyUSB.ps1') -NoShortcuts -NoContextMenu
        Assert-True ($LASTEXITCODE -eq 0) 'Default installation depends on Programs'
        Assert-True (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'CopyUSB\current.txt')) 'Default location missing'
        $env:LOCALAPPDATA = Join-Path $WorkDirectory 'legacy local appdata'
        $legacyTarget = Join-Path $env:LOCALAPPDATA 'Programs\CopyUSB'
        Install-Package $package $legacyTarget $true
        $legacyFirst = Get-Content -LiteralPath (Join-Path $legacyTarget 'current.txt') -Raw
        & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package 'Install-CopyUSB.ps1') -NoShortcuts -NoContextMenu
        Assert-True ($LASTEXITCODE -eq 0) 'Default installer cannot update legacy installation'
        Assert-True ((Get-Content -LiteralPath (Join-Path $legacyTarget 'previous.txt') -Raw) -eq $legacyFirst) 'Legacy installation was not retained'
    }
    finally { $env:LOCALAPPDATA = $savedLocal }
    Install-Package $package $target $true
    $first = Get-Content -LiteralPath (Join-Path $target 'current.txt') -Raw
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'Uninstall-CopyUSB.ps1')) 'Uninstall script was not installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'Uninstall.cmd')) 'Uninstall command was not installed'
    New-Item -ItemType Directory -Path (Join-Path $target 'logs') | Out-Null
    Set-Content -LiteralPath (Join-Path $target 'logs\keep.txt') -Value 'keep'
    & (Join-Path $repo 'Build-Distribution.ps1') -Version 1.0.1 -OutputDirectory $WorkDirectory
    $update = Join-Path $WorkDirectory 'update'
    Expand-Archive -LiteralPath (Join-Path $WorkDirectory 'CopyUSB-1.0.1.zip') -DestinationPath $update
    Install-Package $update $target $true
    $second = Get-Content -LiteralPath (Join-Path $target 'current.txt') -Raw
    Assert-True ($second.StartsWith('1.0.1-')) 'Update was not activated'
    Assert-True ((Get-Content -LiteralPath (Join-Path $target 'previous.txt') -Raw) -eq $first) 'Previous version missing'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'logs\keep.txt')) 'Log lost'
    Assert-True (Test-Path -LiteralPath (Join-Path $target "versions\$first\CopyUSB-GUI.ps1")) 'Old version lost'
    Add-Content -LiteralPath (Join-Path $update 'payload\CopyUSB-GUI.ps1') -Value '# modified'
    Install-Package $update $target $false
    Assert-True ((Get-Content -LiteralPath (Join-Path $target 'current.txt') -Raw) -eq $second) 'Corrupt package changed active version'
    $manifestPath = Join-Path $package 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.Files[0].Path = '..\outside.ps1'
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Install-Package $package $target $false
    $rejected = $false
    try { & (Join-Path $repo 'Build-Distribution.ps1') -Version 2.0.0 -OutputDirectory $WorkDirectory -YafsDirectory (Join-Path $repo 'tools\yafs') }
    catch { if ($_.Exception.Message -notmatch 'Debug dependency') { throw }; $rejected = $true }
    Assert-True $rejected 'Debug YAFS accepted'
    & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $target 'Uninstall-CopyUSB.ps1')
    Assert-True ($LASTEXITCODE -eq 0) 'Unexpected uninstaller result'
    Assert-True (-not (Test-Path -LiteralPath $target)) 'Uninstall did not remove installation'
    Write-Output 'PASS: fresh install, update, retained version/logs, uninstall, corrupt payload, traversal, Debug dependency rejection'
    Write-Output "Test artifacts: $WorkDirectory"
}
catch { throw "Distribution test failed: $($_.Exception.Message)" }
