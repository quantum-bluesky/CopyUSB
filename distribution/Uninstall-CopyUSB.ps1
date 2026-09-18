param(
    [string]$InstallDirectory = '',
    [switch]$KeepLogs
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$step = 'Resolve installation directory'
try {
    if ([string]::IsNullOrWhiteSpace($InstallDirectory)) {
        if ($PSBoundParameters.ContainsKey('InstallDirectory')) { throw 'InstallDirectory must not be empty.' }
        if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'current.txt')) {
            $InstallDirectory = $PSScriptRoot
        }
        else {
            $InstallDirectory = Join-Path $env:LOCALAPPDATA 'CopyUSB'
            $legacy = Join-Path $env:LOCALAPPDATA 'Programs\CopyUSB'
            if (-not (Test-Path -LiteralPath (Join-Path $InstallDirectory 'current.txt'))) {
                try {
                    if (Test-Path -LiteralPath (Join-Path $legacy 'current.txt') -ErrorAction Stop) { $InstallDirectory = $legacy }
                }
                catch { Write-Warning "Cannot inspect old install location: $legacy. Using $InstallDirectory." }
            }
        }
    }
    $root = [IO.Path]::GetFullPath($InstallDirectory)
    Write-Output "Uninstall directory: $root"
    if (-not (Test-Path -LiteralPath $root)) {
        Write-Output 'CopyUSB is not installed at this location.'
        exit 0
    }
    $currentFile = Join-Path $root 'current.txt'
    if (-not (Test-Path -LiteralPath $currentFile)) {
        throw "Not a CopyUSB installation: $root"
    }
    $step = 'Unregister Explorer context menu'
    try {
        $current = (Get-Content -LiteralPath $currentFile -Raw).Trim()
        $register = Join-Path $root "versions\$current\Register-CopyUSBContextMenu.ps1"
        if (Test-Path -LiteralPath $register) {
            & $register -Action Uninstall
        }
        else {
            $menuKey = 'HKCU:\Software\Classes\Directory\shell\CopyUSB-GUI'
            if (Test-Path -LiteralPath $menuKey) { Remove-Item -LiteralPath $menuKey -Recurse -Force }
        }
    }
    catch { Write-Warning ("Context menu could not be removed: " + $_.Exception.Message) }
    $step = 'Remove shortcuts'
    $wsh = $null
    try { $wsh = New-Object -ComObject WScript.Shell }
    catch { Write-Warning ("Shortcut inspection is unavailable: " + $_.Exception.Message) }
    foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
        if ([string]::IsNullOrWhiteSpace($folder)) { continue }
        $shortcut = Join-Path $folder 'CopyUSB.lnk'
        if (Test-Path -LiteralPath $shortcut) {
            try {
                $removeShortcut = $false
                if ($null -ne $wsh) {
                    $link = $wsh.CreateShortcut($shortcut)
                    $targetText = (($link.TargetPath + ' ' + $link.Arguments + ' ' + $link.WorkingDirectory).Trim())
                    $removeShortcut = ($targetText.IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0)
                }
                if ($removeShortcut) { Remove-Item -LiteralPath $shortcut -Force }
            }
            catch { Write-Warning ("Shortcut could not be removed: " + $shortcut + ': ' + $_.Exception.Message) }
        }
    }
    $backupLogs = $null
    if ($KeepLogs) {
        $logs = Join-Path $root 'logs'
        if (Test-Path -LiteralPath $logs) {
            $backupLogs = Join-Path (Split-Path -Parent $root) ('CopyUSB-logs-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            $step = "Preserve logs: $backupLogs"
            Move-Item -LiteralPath $logs -Destination $backupLogs
        }
    }
    $step = "Remove installation directory: $root"
    Set-Location -LiteralPath ([IO.Path]::GetTempPath())
    Remove-Item -LiteralPath $root -Recurse -Force
    Write-Output 'CopyUSB has been uninstalled.'
    if ($backupLogs) { Write-Output "Logs preserved at: $backupLogs" }
}
catch { Write-Error "Uninstall failed during [$step]: $($_.Exception.Message)" -ErrorAction Continue; exit 1 }
