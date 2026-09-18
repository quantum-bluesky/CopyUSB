param(
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version = '1.0.0',
    [ValidateNotNullOrEmpty()][string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'),
    [string]$YafsDirectory = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    $output = [IO.Path]::GetFullPath($OutputDirectory)
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $zip = Join-Path $output "CopyUSB-$Version.zip"
    if (Test-Path -LiteralPath $zip) { throw "Package already exists: $zip. Use a new version or output directory." }
    $stage = Join-Path $output ('build-' + [guid]::NewGuid().ToString('N'))
    $payload = Join-Path $stage 'payload'
    New-Item -ItemType Directory -Path $payload -Force | Out-Null
    $files = @('CopyUSB-GUI.ps1', 'master_copy_check_eject.ps1', 'check_copy_hash.ps1',
        'Check-UsbDisk.ps1', 'Mp3FatSort.ps1', 'removedrv.ps1', 'Remount-Usb.ps1',
        'Register-CopyUSBContextMenu.ps1', 'README.md', 'HUONG_DAN_SU_DUNG.md', 'LICENSE')
    foreach ($file in $files) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $payload }
    $hasYafs = -not [string]::IsNullOrWhiteSpace($YafsDirectory)
    if ($hasYafs) {
        foreach ($required in @('yafs.exe', 'COPYING', 'fat_file_system_tree.xsd')) {
            if (-not (Test-Path -LiteralPath (Join-Path $YafsDirectory $required))) { throw "Missing YAFS component: $required" }
        }
        foreach ($binary in Get-ChildItem -LiteralPath $YafsDirectory -File | Where-Object { $_.Extension -in '.exe', '.dll' }) {
            $binaryText = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($binary.FullName))
            if ($binaryText -match '(?i)(MSVCP\d+D|VCRUNTIME\d+(?:_\d+)?D|ucrtbased|xerces-c_[\d_]+D)\.dll') {
                throw "Debug dependency in $($binary.Name). Supply a Release build; Debug VC runtimes cannot be distributed."
            }
        }
        New-Item -ItemType Directory -Path (Join-Path $payload 'tools') | Out-Null
        Copy-Item -LiteralPath $YafsDirectory -Destination (Join-Path $payload 'tools\yafs') -Recurse
    }
    foreach ($file in @('Install-CopyUSB.ps1', 'Launch-CopyUSB.ps1', 'Uninstall-CopyUSB.ps1', 'Install.cmd', 'Uninstall.cmd', 'HUONG_DAN_CAI_DAT.md')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "distribution\$file") -Destination $stage
    }
    $entries = @(Get-ChildItem -LiteralPath $payload -Recurse -File | ForEach-Object {
        @{ Path = $_.FullName.Substring($payload.Length + 1); SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    })
    @{ Product = 'CopyUSB'; Version = $Version; HasYafs = $hasYafs; Files = $entries } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'manifest.json') -Encoding UTF8
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
    (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash | Set-Content -LiteralPath "$zip.sha256" -Encoding ASCII
    Write-Output "Package: $zip"
    Write-Output "Build directory retained: $stage"
}
catch { throw "Build failed: $($_.Exception.Message)" }
