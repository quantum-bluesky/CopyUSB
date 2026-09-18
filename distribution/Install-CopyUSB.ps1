param(
    [string]$InstallDirectory = '',
    [switch]$NoShortcuts,
    [switch]$NoContextMenu
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$lock = $null
$step = 'Resolve installation directory'
try {
    if ([string]::IsNullOrWhiteSpace($InstallDirectory)) {
        if ($PSBoundParameters.ContainsKey('InstallDirectory')) { throw 'InstallDirectory must not be empty.' }
        $InstallDirectory = Join-Path $env:LOCALAPPDATA 'CopyUSB'
        $legacy = Join-Path $env:LOCALAPPDATA 'Programs\CopyUSB'
        # Keep updates at the previous location when its installation is readable.
        if (-not (Test-Path -LiteralPath (Join-Path $InstallDirectory 'current.txt'))) {
            try {
                if (Test-Path -LiteralPath (Join-Path $legacy 'current.txt') -ErrorAction Stop) { $InstallDirectory = $legacy }
            }
            catch { Write-Warning "Cannot inspect old install location: $legacy. Using $InstallDirectory." }
        }
    }
    $root = [IO.Path]::GetFullPath($InstallDirectory)
    Write-Output "Install directory: $root"
    $step = 'Validate package'
    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.Product -ne 'CopyUSB' -or $manifest.Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Invalid package manifest.' }
    $payload = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'payload')) + '\'
    $seen = @{}
    foreach ($entry in $manifest.Files) {
        $path = [IO.Path]::GetFullPath((Join-Path $payload $entry.Path))
        if ([IO.Path]::IsPathRooted($entry.Path) -or $entry.Path -match '(^|[\\/])\.\.([\\/]|$)|:' -or -not $path.StartsWith($payload, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe package path.' }
        if ($seen.ContainsKey($entry.Path)) { throw 'Duplicate package path.' }
        $seen[$entry.Path] = $true
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.SHA256) { throw "Checksum mismatch: $($entry.Path)" }
    }
    foreach ($required in @('CopyUSB-GUI.ps1', 'master_copy_check_eject.ps1', 'Register-CopyUSBContextMenu.ps1')) {
        if (-not $seen.ContainsKey($required)) { throw "Incomplete package: $required" }
    }
    $step = "Create installation directory: $root"
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $step = "Acquire installation lock: $root"
    $lock = [IO.File]::Open((Join-Path $root '.install.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $release = $manifest.Version + '-' + [guid]::NewGuid().ToString('N')
    $app = Join-Path $root "versions\$release"
    $step = "Copy application files: $app"
    New-Item -ItemType Directory -Path $app -Force | Out-Null
    foreach ($entry in $manifest.Files) {
        $target = Join-Path $app $entry.Path
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $payload $entry.Path) -Destination $target
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $entry.SHA256) { throw "Installed checksum mismatch: $($entry.Path)" }
        Unblock-File -LiteralPath $target
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Destination $app
    $step = "Update launcher: $root"
    $launcher = Join-Path $root 'Launch-CopyUSB.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Launch-CopyUSB.ps1') -Destination $launcher -Force
    Unblock-File -LiteralPath $launcher
    foreach ($uninstallFile in @('Uninstall-CopyUSB.ps1', 'Uninstall.cmd')) {
        $uninstallSource = Join-Path $PSScriptRoot $uninstallFile
        if (Test-Path -LiteralPath $uninstallSource) {
            $uninstallTarget = Join-Path $root $uninstallFile
            Copy-Item -LiteralPath $uninstallSource -Destination $uninstallTarget -Force
            Unblock-File -LiteralPath $uninstallTarget
        }
    }
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $step = "Activate installed version: $root"
    $current = Join-Path $root 'current.txt'
    $pending = Join-Path $root 'current.pending'
    [IO.File]::WriteAllText($pending, $release)
    if (Test-Path -LiteralPath $current) {
        [IO.File]::Replace($pending, $current, (Join-Path $root 'previous.txt'))
    }
    else { [IO.File]::Move($pending, $current) }
    if (-not $NoShortcuts) {
        try {
        $wsh = New-Object -ComObject WScript.Shell
        foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
            $shortcut = $wsh.CreateShortcut((Join-Path $folder 'CopyUSB.lnk'))
            $shortcut.TargetPath = $shell
            $shortcut.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $launcher + '"'
            $shortcut.WorkingDirectory = $root
            $shortcut.Save()
        }
        } catch { Write-Warning ("Shortcut could not be created: " + $_.Exception.Message) }
    }
    if (-not $NoContextMenu) {
        try { & (Join-Path $app 'Register-CopyUSBContextMenu.ps1') -Action Install -GuiScriptPath $launcher }
        catch { Write-Warning ("Context menu could not be registered: " + $_.Exception.Message) }
    }
    Write-Output "To start manually: powershell -NoProfile -STA -ExecutionPolicy Bypass -File ""$launcher"""
    Write-Output "Installed CopyUSB $($manifest.Version) at $root"
}
catch { Write-Error "Installation failed during [$step]: $($_.Exception.Message)" -ErrorAction Continue; exit 1 }
finally { if ($null -ne $lock) { $lock.Dispose() } }
