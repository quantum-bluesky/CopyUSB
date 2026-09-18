param(
    [ValidateSet('x86', 'x64')][string]$Architecture = 'x86',
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version = '1.0.0',
    [ValidateNotNullOrEmpty()][string]$YafsSourceDirectory = (Join-Path $PSScriptRoot 'yafs'),
    [ValidateNotNullOrEmpty()][string]$XercesSourceDirectory = (Join-Path $PSScriptRoot 'xerces-c-3.3.0'),
    [ValidateNotNullOrEmpty()][string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist\yafs'),
    [ValidateRange(1, 64)][int]$Jobs = 4
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Invoke-BuildTool {
    param([string]$Tool, [string[]]$Arguments)
    & $Tool @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Tool failed ($LASTEXITCODE): $Tool $($Arguments -join ' ')" }
}
try {
    $yafsSource = [IO.Path]::GetFullPath($YafsSourceDirectory)
    $xercesSource = [IO.Path]::GetFullPath($XercesSourceDirectory)
    foreach ($path in @((Join-Path $yafsSource 'main.cpp'), (Join-Path $xercesSource 'CMakeLists.txt'))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing source: $path. No automatic download is performed." }
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Install Visual Studio 2022 / Build Tools with Desktop development with C++, Windows SDK and CMake tools.' }
    $vsPath = & $vswhere -latest -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vsPath)) { throw 'Visual Studio 2022 C++ x86/x64 toolchain not found.' }
    $cmake = Join-Path $vsPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    if (-not (Test-Path -LiteralPath $cmake)) {
        $cmakeCommand = Get-Command cmake.exe -ErrorAction Stop
        $cmake = $cmakeCommand.Source
    }
    $msvcVersion = (Get-Content -LiteralPath (Join-Path $vsPath 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt') -Raw).Trim()
    $dumpbin = Join-Path $vsPath "VC\Tools\MSVC\$msvcVersion\bin\Hostx64\$Architecture\dumpbin.exe"
    if (-not (Test-Path -LiteralPath $dumpbin)) { throw "Missing dependency inspector: $dumpbin" }
    $output = [IO.Path]::GetFullPath($OutputDirectory)
    $build = Join-Path $output "build-$Architecture"
    $release = Join-Path $output "$Version-$Architecture"
    $runtimeZip = Join-Path $output "YAFS-$Version-$Architecture.zip"
    if (Test-Path -LiteralPath $runtimeZip) { throw "Archive already exists: $runtimeZip" }
    if (Test-Path -LiteralPath $release) { throw "Release already exists: $release. Use a new version or output directory." }
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $platform = if ($Architecture -eq 'x86') { 'Win32' } else { 'x64' }
    Invoke-BuildTool $cmake @('-S', (Join-Path $PSScriptRoot 'distribution\yafs'), '-B', $build,
        '-G', 'Visual Studio 17 2022', '-A', $platform, "-DCMAKE_GENERATOR_INSTANCE=$vsPath",
        "-DYAFS_SOURCE_DIR=$yafsSource", "-DXERCES_SOURCE_DIR=$xercesSource", "-DYAFS_VERSION=$Version")
    Invoke-BuildTool $cmake @('--build', $build, '--config', 'Release', '--target', 'yafs', 'yafs-xml-smoke', '--parallel', "$Jobs")
    $exe = Join-Path $build 'Release\yafs.exe'
    $dependencies = & $dumpbin /DEPENDENTS $exe
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect PE dependencies.' }
    $dlls = @($dependencies | ForEach-Object { if ($_ -match '^\s+([\w.-]+\.dll)\s*$') { $Matches[1] } })
    if ($dlls.Count -eq 0) { throw 'No PE dependencies found; cannot verify standalone runtime.' }
    $allowed = @('KERNEL32.dll', 'ADVAPI32.dll', 'USER32.dll', 'SHELL32.dll', 'OLE32.dll', 'OLEAUT32.dll', 'WS2_32.dll', 'BCRYPT.dll', 'CRYPT32.dll')
    foreach ($dll in $dlls) { if ($dll -notin $allowed) { throw "Unexpected dependency: $dll. Release must use static Xerces and /MT." } }
    New-Item -ItemType Directory -Path $release | Out-Null
    Copy-Item -LiteralPath $exe -Destination $release
    foreach ($file in @('COPYING', 'fat_file_system_tree.xsd')) { Copy-Item -LiteralPath (Join-Path $yafsSource $file) -Destination $release }
    Copy-Item -LiteralPath (Join-Path $xercesSource 'LICENSE') -Destination (Join-Path $release 'XERCES-LICENSE.txt')
    Copy-Item -LiteralPath (Join-Path $xercesSource 'NOTICE') -Destination (Join-Path $release 'XERCES-NOTICE.txt')
    # Test from the release directory with only Windows in PATH, never against a disk.
    $savedPath = $env:PATH
    Push-Location -LiteralPath $release
    try {
        $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
        $help = Start-Process -FilePath (Join-Path $release 'yafs.exe') -ArgumentList '-h' -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $release 'help.stdout.txt') -RedirectStandardError (Join-Path $release 'help.stderr.txt')
        if ($help.ExitCode -ne 0 -or (Get-Content -LiteralPath (Join-Path $release 'help.stderr.txt') -Raw) -notmatch 'Usage: yafs') { throw "YAFS startup test failed: $($help.ExitCode)" }
        Invoke-BuildTool (Join-Path $build 'Release\yafs-xml-smoke.exe') @()
    }
    finally { $env:PATH = $savedPath; Pop-Location }
    @{ Version = $Version; Architecture = $Architecture; Runtime = 'MSVC /MT Release'; Xerces = '3.3.0 static'; Dependencies = $dlls; SHA256 = (Get-FileHash -LiteralPath (Join-Path $release 'yafs.exe') -Algorithm SHA256).Hash } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $release 'build-info.json') -Encoding UTF8
    # Ship the matching sources and build recipe together with the binary.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $sourceZip = Join-Path $release 'source.zip'
    $archive = [IO.Compression.ZipFile]::Open($sourceZip, 'Create')
    try {
        $sourceFiles = @()
        $sourceFiles += Get-ChildItem -LiteralPath $yafsSource -File | Where-Object { $_.Extension -in '.cpp', '.h', '.xsd' -or $_.Name -in 'COPYING', 'README.md', 'sources' -or $_.Name -like 'Makefile_*' } | ForEach-Object { @{ File = $_.FullName; Entry = 'yafs/' + $_.Name } }
        # Prune generated directories before traversing the Xerces source tree.
        $queue = New-Object 'System.Collections.Generic.Queue[string]'
        $queue.Enqueue($xercesSource)
        while ($queue.Count) {
            $dir = $queue.Dequeue()
            foreach ($item in Get-ChildItem -LiteralPath $dir -Force) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($item.PSIsContainer) { if ($item.Name -notin @('build', '.git', '.vs', 'CMakeFiles', 'Testing')) { $queue.Enqueue($item.FullName) } }
                else { $sourceFiles += @{ File = $item.FullName; Entry = 'xerces-c-3.3.0/' + $item.FullName.Substring($xercesSource.Length + 1).Replace('\', '/') } }
            }
        }
        $sourceFiles += @{ File = $PSCommandPath; Entry = 'Build-Yafs.ps1' }
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'distribution\yafs') -File) { $sourceFiles += @{ File = $file.FullName; Entry = 'distribution/yafs/' + $file.Name } }
        foreach ($file in $sourceFiles) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.File, $file.Entry) }
    }
    finally { $archive.Dispose() }
    Compress-Archive -Path (Join-Path $release '*') -DestinationPath $runtimeZip
    (Get-FileHash -LiteralPath $runtimeZip -Algorithm SHA256).Hash | Set-Content -LiteralPath "$runtimeZip.sha256" -Encoding ASCII
    Write-Output "YAFS_ARCHIVE=$runtimeZip"
    Write-Output "YAFS_RELEASE=$release"
    Write-Output "PASS: Release build, system DLL dependencies, startup and XML smoke test."
}
catch { throw "YAFS build failed: $($_.Exception.Message)" }
