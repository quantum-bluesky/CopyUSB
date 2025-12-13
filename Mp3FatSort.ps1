<#
.SYNOPSIS
  Check/sort FAT directory order on one or more drives using YAFS.

.DESCRIPTION
  Uses YAFS to read/write FAT directory order via an XML tree.
  By default, only media files (audio/video) are checked/sorted; non-media files are ignored.

.PARAMETER Device
  One or more drive letters in YAFS format (e.g. 'f:').
  You can also pass a comma-separated list: -Device 'f:,g:,h:'
  Invalid/unavailable drives are skipped.

.PARAMETER Mode
  CheckOnly | SortOnlyAuto | SortOnlyFromTree | CheckAndSort

.PARAMETER SortScope
  Both (dir-first), FoldersOnly, FilesOnly.

.PARAMETER FileFilter
  MediaOnly (default) to only check/sort audio/video files, or AllFiles.

.PARAMETER NoParallel
  Force sequential processing when multiple drives are provided.

.PARAMETER ThrottleLimit
  Max concurrent drives when running in parallel.

.PARAMETER InstallYafs
  Copies bundled YAFS binaries from '.\yafs\bin' into the folder containing -YafsPath.

.EXAMPLE
  .\Mp3FatSort.ps1 -Device 'f:' -Mode CheckOnly

.EXAMPLE
  .\Mp3FatSort.ps1 -Device 'f:,g:,h:' -Mode CheckOnly

.EXAMPLE
  .\Mp3FatSort.ps1 -InstallYafs -YafsPath 'C:\Tools\yafs\yafs.exe'

.NOTES
  If YAFS reports 'Error while locking the file "\\.\f:". Access is denied.',
  close Explorer/apps using the drive and/or run PowerShell as Administrator.
  Build guide: .\yafs\BuildGuide.md
#>

[CmdletBinding(DefaultParameterSetName="Run")]
param(
  [Parameter(ParameterSetName="Run")]
  [Parameter(ParameterSetName="InstallYafs")]
  [string]$YafsPath="C:\Tools\yafs\yafs.exe",

  [Parameter(Mandatory=$true, ParameterSetName="Run")]
  [string[]]$Device,

  [Parameter(Mandatory=$true, ParameterSetName="Run")]
  [ValidateSet("CheckOnly","SortOnlyAuto","SortOnlyFromTree","CheckAndSort")]
  [string]$Mode,

  # Sort scope
  # - Both        : sort directory + file at every level (default)
  # - FoldersOnly : only sort <directory> siblings; keep <file> order as-is
  # - FilesOnly   : only sort <file> siblings; keep <directory> order as-is
  [Parameter(ParameterSetName="Run")]
  [ValidateSet("Both","FoldersOnly","FilesOnly")]
  [string]$SortScope = "Both",

  # File filtering
  # Default: only sort/check media files (audio/video). Non-media files are ignored.
  [Parameter(ParameterSetName="Run")]
  [ValidateSet("MediaOnly","AllFiles")]
  [string]$FileFilter = "MediaOnly",

  # Where to dump current tree (from yafs -r). Default: .\tree.xml
  [Parameter(ParameterSetName="Run")]
  [string]$TreeOut = (Join-Path (Get-Location) "tree.xml"),

  # Where to write sorted tree xml. Default: .\tree_sorted.xml
  [Parameter(ParameterSetName="Run")]
  [string]$SortedTreeOut = (Join-Path (Get-Location) "tree_sorted.xml"),

  # Tree file to apply (for SortOnlyFromTree). If omitted, use -SortedTreeOut
  [Parameter(ParameterSetName="Run")]
  [string]$TreeIn,

  # Confirm before writing to device (unless -Force)
  [Parameter(ParameterSetName="Run")]
  [switch]$Force,

  # Verbose-ish logging
  [Parameter(ParameterSetName="Run")]
  [Parameter(ParameterSetName="InstallYafs")]
  [switch]$VerboseLog,

  [Parameter(ParameterSetName="Run")]
  [switch]$NoParallel,

  [Parameter(ParameterSetName="Run")]
  [ValidateRange(1,64)]
  [int]$ThrottleLimit = 4,

  [Parameter(Mandatory=$true, ParameterSetName="Help")]
  [Alias("h","?")]
  [switch]$Help,

  [Parameter(Mandatory=$true, ParameterSetName="InstallYafs")]
  [switch]$InstallYafs,

  [Parameter(ParameterSetName="InstallYafs")]
  [string]$YafsSourceDir = (Join-Path $PSScriptRoot "yafs\bin")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log([string]$msg) {
  if ($VerboseLog) { Write-Host $msg }
}

function Show-ScriptHelp {
  Get-Help -Name $PSCommandPath -Detailed | Out-Host
  Write-Host ""
  Write-Host "YAFS build guide: $(Join-Path $PSScriptRoot 'yafs\BuildGuide.md')"
}

function Normalize-DeviceToken([string]$token) {
  if ($null -eq $token) { return $null }
  $t = $token.Trim()
  if ($t.Length -eq 0) { return $null }

  $t = $t.Trim("'").Trim('"')
  $t = $t.TrimEnd('\','/')

  if ($t -match '^[A-Za-z]$') { return ($t.ToLowerInvariant() + ":") }
  if ($t -match '^[A-Za-z]:$') { return ($t.Substring(0,1).ToLowerInvariant() + ":") }
  if ($t -match '^[A-Za-z]:') { return ($t.Substring(0,1).ToLowerInvariant() + ":") }

  return $null
}

function Parse-DeviceList([string[]]$deviceArgs) {
  $raw = ($deviceArgs | Where-Object { $null -ne $_ }) -join ","
  $tokens = $raw -split '[,;\s]+'

  $out = New-Object System.Collections.Generic.List[string]
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($tok in $tokens) {
    $d = Normalize-DeviceToken $tok
    if ($null -eq $d) { continue }
    if ($seen.Add($d)) { [void]$out.Add($d) }
  }
  return ,$out.ToArray()
}

function Test-DeviceReady([string]$device) {
  if ($null -eq $device -or $device -notmatch '^[A-Za-z]:$') { return $false }
  $root = "$device\\"
  try {
    return (Test-Path -LiteralPath $root)
  } catch {
    return $false
  }
}

function Get-DeviceSpecificPath([string]$basePath, [string]$device) {
  $dir = Split-Path -Parent $basePath
  if ($null -eq $dir -or $dir.Trim().Length -eq 0) { $dir = (Get-Location).Path }

  $name = [IO.Path]::GetFileNameWithoutExtension($basePath)
  $ext = [IO.Path]::GetExtension($basePath)
  if ($null -eq $ext -or $ext.Length -eq 0) { $ext = ".xml" }

  $d = $device.TrimEnd(':')
  return (Join-Path $dir ("{0}_{1}{2}" -f $name, $d, $ext))
}

function Get-SelfPowerShellExe {
  try {
    $p = Get-Process -Id $PID -ErrorAction Stop
    if ($p.Path -and (Test-Path -LiteralPath $p.Path)) { return $p.Path }
  } catch {
    # fall through
  }

  if ($PSVersionTable.PSEdition -eq "Core") { return (Join-Path $PSHOME "pwsh.exe") }
  return (Join-Path $PSHOME "powershell.exe")
}

function Get-OverallExitCode([int[]]$codes) {
  if ($codes -contains 4) { return 4 }
  if ($codes -contains 3) { return 3 }
  if ($codes -contains 1) { return 1 }
  if ($codes -contains 2) { return 2 }
  return 0
}

function Install-YafsBinaries([string]$targetYafsPath, [string]$sourceDir) {
  $srcExe = Join-Path $sourceDir "yafs.exe"
  if (-not (Test-Path -LiteralPath $srcExe)) {
    throw "YAFS binary not found at: $srcExe (build it first, see: $(Join-Path $PSScriptRoot 'yafs\BuildGuide.md'))"
  }

  $targetDir = Split-Path -Parent $targetYafsPath
  if ($null -eq $targetDir -or $targetDir.Trim().Length -eq 0) { throw "Invalid YafsPath: $targetYafsPath" }
  New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

  Copy-Item -Force -LiteralPath $srcExe -Destination $targetYafsPath

  $srcDll = Join-Path $sourceDir "xerces-c_3_3D.dll"
  if (Test-Path -LiteralPath $srcDll) {
    Copy-Item -Force -LiteralPath $srcDll -Destination (Join-Path $targetDir "xerces-c_3_3D.dll")
  }

  Write-Host "YAFS_INSTALLED: $targetYafsPath"
}

function Invoke-MultiDeviceRun(
  [string[]]$devices,
  [string]$pwshExe,
  [string]$scriptPath,
  [string]$yafsPath,
  [string]$mode,
  [string]$sortScope,
  [string]$fileFilter,
  [string]$treeOutBase,
  [string]$sortedTreeOutBase,
  [string]$treeIn,
  [switch]$force,
  [switch]$verboseLog,
  [switch]$noParallel,
  [int]$throttleLimit
) {
  $needsPrompt = (-not $force) -and ($mode -ne "CheckOnly")
  $runParallel = (-not $noParallel) -and ($devices.Count -gt 1) -and (-not $needsPrompt)

  if ($mode -eq "SortOnlyFromTree" -and (-not $treeIn) -and (-not (Test-Path -LiteralPath $sortedTreeOutBase))) {
    throw "SortOnlyFromTree needs -TreeIn (or an existing -SortedTreeOut file)."
  }

  if ($needsPrompt -and $devices.Count -gt 1 -and -not $noParallel) {
    Write-Host "NOTE: multiple devices + confirmation prompt -> running sequential. Add -Force to enable parallel."
  }

  $results = @()

  if ($runParallel) {
    $jobs = @()
    foreach ($d in $devices) {
      $treeOut = Get-DeviceSpecificPath $treeOutBase $d
      $sortedOut = if ($mode -eq "SortOnlyFromTree") { $sortedTreeOutBase } else { Get-DeviceSpecificPath $sortedTreeOutBase $d }

      $argsList = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$scriptPath,
        "-YafsPath",$yafsPath,
        "-Device",$d,
        "-Mode",$mode,
        "-SortScope",$sortScope,
        "-FileFilter",$fileFilter,
        "-TreeOut",$treeOut,
        "-SortedTreeOut",$sortedOut
      )
      if ($treeIn) { $argsList += @("-TreeIn",$treeIn) }
      if ($force) { $argsList += "-Force" }
      if ($verboseLog) { $argsList += "-VerboseLog" }

      $outDir = Split-Path -Parent $treeOut
      if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

      $jobs += Start-Job -ArgumentList @($pwshExe,$argsList,$d) -ScriptBlock {
        param($exe,$a,$dev)
        $o = & $exe @a 2>&1
        $c = $LASTEXITCODE
        $t = ""
        if ($null -ne $o) { $t = ($o | Out-String).TrimEnd() }
        [pscustomobject]@{ Device = $dev; ExitCode = $c; Output = $t }
      }

      while ($jobs.Count -ge $throttleLimit) {
        $done = Wait-Job -Job $jobs -Any
        $results += Receive-Job -Job $done
        Remove-Job -Job $done
        $jobs = @($jobs | Where-Object { $_.Id -ne $done.Id })
      }
    }

    if ($jobs.Count -gt 0) {
      Wait-Job -Job $jobs | Out-Null
      $results += Receive-Job -Job $jobs
      Remove-Job -Job $jobs
    }
  }
  else {
    foreach ($d in $devices) {
      $treeOut = Get-DeviceSpecificPath $treeOutBase $d
      $sortedOut = if ($mode -eq "SortOnlyFromTree") { $sortedTreeOutBase } else { Get-DeviceSpecificPath $sortedTreeOutBase $d }

      $argsList = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$scriptPath,
        "-YafsPath",$yafsPath,
        "-Device",$d,
        "-Mode",$mode,
        "-SortScope",$sortScope,
        "-FileFilter",$fileFilter,
        "-TreeOut",$treeOut,
        "-SortedTreeOut",$sortedOut
      )
      if ($treeIn) { $argsList += @("-TreeIn",$treeIn) }
      if ($force) { $argsList += "-Force" }
      if ($verboseLog) { $argsList += "-VerboseLog" }

      $outDir = Split-Path -Parent $treeOut
      if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

      $o = & $pwshExe @argsList 2>&1
      $c = $LASTEXITCODE
      $t = ""
      if ($null -ne $o) { $t = ($o | Out-String).TrimEnd() }
      $results += [pscustomobject]@{ Device = $d; ExitCode = $c; Output = $t }
    }
  }

  foreach ($r in $results) {
    if ($r.Output) {
      foreach ($line in ($r.Output -split "`r?`n")) {
        if ($line -ne "") { Write-Host ("[{0}] {1}" -f $r.Device, $line) }
      }
    } else {
      Write-Host ("[{0}] (no output)" -f $r.Device)
    }
  }

  $codes = @($results | ForEach-Object { [int]$_.ExitCode })
  return (Get-OverallExitCode $codes)
}

function Test-IsAdministrator {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = [Security.Principal.WindowsPrincipal]::new($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
  } catch {
    return $false
  }
}

function Invoke-Yafs([string]$yafs, [string[]]$yafsArgs) {
  $output = & $yafs @yafsArgs 2>&1
  $code = $LASTEXITCODE
  $text = ""
  if ($null -ne $output) { $text = ($output | Out-String).TrimEnd() }
  return [pscustomobject]@{ ExitCode = $code; Output = $text }
}

function Test-Executable([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) {
    throw "YAFS not found: $path (tip: run .\\Mp3FatSort.ps1 -InstallYafs -YafsPath `"$path`")"
  }
}

function Invoke-YafsRead([string]$yafs, [string]$device, [string]$outFile) {
  Write-Log "Running: $yafs -d $device -r -f `"$outFile`""
  $maxRetry = 1
  $delayMs = 500
  for ($attempt = 1; $attempt -le ($maxRetry + 1); $attempt++) {
    $r = Invoke-Yafs $yafs @("-d",$device,"-r","-f",$outFile)
    if ($r.ExitCode -eq 0) { return }

    $isLockDenied = ($r.Output -match 'locking the file' -and $r.Output -match 'Access is denied')
    if ($isLockDenied -and $attempt -le $maxRetry) {
      Start-Sleep -Milliseconds $delayMs
      continue
    }

    if ($isLockDenied) {
      $elev = if (Test-IsAdministrator) { "elevated" } else { "NOT elevated" }
      throw ("yafs -r failed (cannot lock \\.\{0}) [session: {1}]. Close Explorer/windows/apps using {0}, then retry; if still fails, run PowerShell as Administrator.`n{2}" -f $device, $elev, $r.Output)
    }

    if ($r.Output) { throw ("yafs -r failed with code {0}`n{1}" -f $r.ExitCode, $r.Output) }
    throw ("yafs -r failed with code {0}" -f $r.ExitCode)
  }
}

function Invoke-YafsWrite([string]$yafs, [string]$device, [string]$inFile) {
  Write-Log "Running: $yafs -d $device -w -f `"$inFile`""
  $maxRetry = 1
  $delayMs = 500
  for ($attempt = 1; $attempt -le ($maxRetry + 1); $attempt++) {
    $r = Invoke-Yafs $yafs @("-d",$device,"-w","-f",$inFile)
    if ($r.ExitCode -eq 0) { return }

    $isLockDenied = ($r.Output -match 'locking the file' -and $r.Output -match 'Access is denied')
    if ($isLockDenied -and $attempt -le $maxRetry) {
      Start-Sleep -Milliseconds $delayMs
      continue
    }

    if ($isLockDenied) {
      $elev = if (Test-IsAdministrator) { "elevated" } else { "NOT elevated" }
      throw ("yafs -w failed (cannot lock \\.\{0}) [session: {1}]. Close Explorer/windows/apps using {0}, then retry; if still fails, run PowerShell as Administrator.`n{2}" -f $device, $elev, $r.Output)
    }

    if ($r.Output) { throw ("yafs -w failed with code {0}`n{1}" -f $r.ExitCode, $r.Output) }
    throw ("yafs -w failed with code {0}" -f $r.ExitCode)
  }
}

function Load-Xml([string]$file) {
  $xml = New-Object xml
  $xml.PreserveWhitespace = $true
  $xml.Load($file)
  return $xml
}

function Save-Xml([xml]$xml, [string]$file) {
  $xml.Save($file)
}

function Get-Name([xml]$xml, $node) {
  # Prefer long_name, fallback short_name
  # (Avoid $node.long_name property access because under StrictMode it throws when the element is absent.)
  $lnNode = $node.SelectSingleNode("long_name")
  if ($null -ne $lnNode) {
    $ln = $lnNode.InnerText
    if ($null -ne $ln -and $ln.Trim().Length -gt 0) { return $ln.Trim() }
  }

  $snNode = $node.SelectSingleNode("short_name")
  if ($null -ne $snNode) {
    $sn = $snNode.InnerText
    if ($null -ne $sn -and $sn.Trim().Length -gt 0) { return $sn.Trim() }
  }
  return ""
}

function Is-DirectoryNode($node) { return $node.Name -eq "directory" }
function Is-FileNode($node) { return $node.Name -eq "file" }

function Is-MediaFileName([string]$name) {
  if ($null -eq $name) { return $false }
  $ext = [IO.Path]::GetExtension($name)
  if ($null -eq $ext -or $ext.Length -le 1) { return $false }
  $e = $ext.Substring(1).ToLowerInvariant()
  switch ($e) {
    # audio
    "mp3" { return $true }
    "m4a" { return $true }
    "aac" { return $true }
    "wav" { return $true }
    "flac" { return $true }
    "ogg" { return $true }
    "opus" { return $true }
    "wma" { return $true }
    # video
    "mp4" { return $true }
    "mkv" { return $true }
    "avi" { return $true }
    "mov" { return $true }
    "m4v" { return $true }
    "3gp" { return $true }
    "webm" { return $true }
    default { return $false }
  }
}

function Is-MediaFileNode([xml]$xml, $node) {
  if (-not (Is-FileNode $node)) { return $false }
  $n = Get-Name $xml $node
  return (Is-MediaFileName $n)
}

function Should-ConsiderNodeForSort([xml]$xml, $node, [string]$sortScope, [string]$fileFilter) {
  if ($node.NodeType -ne [System.Xml.XmlNodeType]::Element) { return $false }
  if (-not (Is-DirectoryNode $node) -and -not (Is-FileNode $node)) { return $false }
  if (Should-SkipNode $xml $node) { return $false }

  if ($sortScope -eq "FoldersOnly") { return (Is-DirectoryNode $node) }
  if ($sortScope -eq "FilesOnly") {
    if (-not (Is-FileNode $node)) { return $false }
    if ($fileFilter -eq "AllFiles") { return $true }
    return (Is-MediaFileNode $xml $node)
  }

  # Both
  if (Is-DirectoryNode $node) { return $true }
  if (-not (Is-FileNode $node)) { return $false }
  if ($fileFilter -eq "AllFiles") { return $true }
  return (Is-MediaFileNode $xml $node)
}

function Should-SkipNode([xml]$xml, $node) {
  if (Is-DirectoryNode $node) {
    $n = Get-Name $xml $node
    if ($n -ieq "System Volume Information") { return $true }
  }
  if (Is-FileNode $node) {
    $n = Get-Name $xml $node
    if ($n -ieq "desktop.ini") { return $true }
  }
  return $false
}

function Natural-KeyParts([string]$s) {
  $parts = @()
  foreach ($m in [regex]::Split($s, '(\d+)')) {
    if ($m -eq "") { continue }
    if ($m -match '^\d+$') { $parts += [int]$m }
    else { $parts += $m.ToLowerInvariant() }
  }
  return ,$parts
}

function Compare-Natural([string]$a, [string]$b) {
  $ka = Natural-KeyParts $a
  $kb = Natural-KeyParts $b
  $len = [Math]::Min($ka.Count, $kb.Count)
  for ($i=0; $i -lt $len; $i++) {
    $pa = $ka[$i]; $pb = $kb[$i]
    if ($pa.GetType().Name -eq "Int32" -and $pb.GetType().Name -eq "Int32") {
      if ($pa -lt $pb) { return -1 }
      if ($pa -gt $pb) { return 1 }
    } else {
      $sa = "$pa"; $sb = "$pb"
      $c = [string]::Compare($sa, $sb, $true)
      if ($c -ne 0) { return $c }
    }
  }
  if ($ka.Count -lt $kb.Count) { return -1 }
  if ($ka.Count -gt $kb.Count) { return 1 }
  return 0
}

function Confirm-Apply([string]$device, [string]$file) {
  $q = "Apply sorted FAT order to device '$device' using tree file '$file'?"
  $ans = Read-Host "$q (Y/N)"
  return ($ans -match '^(y|yes)$')
}

function Sort-ArrayByNaturalName([xml]$xml, [object[]]$arr) {
  # Insertion sort using Compare-Natural
  for ($i=1; $i -lt $arr.Count; $i++) {
    $tmp = $arr[$i]
    $j = $i - 1
    while ($j -ge 0 -and (Compare-Natural (Get-Name $xml $arr[$j]) (Get-Name $xml $tmp)) -gt 0) {
      $arr[$j+1] = $arr[$j]
      $j--
    }
    $arr[$j+1] = $tmp
  }
  # Prevent PowerShell from unrolling a single-item array into a scalar XmlElement
  return ,$arr
}

function Sort-Siblings([xml]$xml, $parentNode, [string]$sortScope, [string]$fileFilter) {
  # Consider only eligible nodes, but keep all other nodes in place.
  $allNodes = @($parentNode.ChildNodes)

  $kids = @()
  foreach ($child in $allNodes) {
    if (Should-ConsiderNodeForSort $xml $child $sortScope $fileFilter) {
      $kids += $child
    }
  }
  if ($kids.Count -eq 0) { return $false }

  # Build desired order
  $desired = @()

  if ($sortScope -eq "FoldersOnly" -or $sortScope -eq "FilesOnly") {
    $desired = Sort-ArrayByNaturalName $xml (@($kids))
  }
  else {
    # Both: dir-first, natural sort within each group
    $desiredDirs = @()
    $desiredFiles = @()
    foreach ($k in $kids) {
      if (Is-DirectoryNode $k) { $desiredDirs += $k } else { $desiredFiles += $k }
    }
    if ($desiredDirs.Count -gt 0) { $desiredDirs = Sort-ArrayByNaturalName $xml (@($desiredDirs)) }
    if ($desiredFiles.Count -gt 0) { $desiredFiles = Sort-ArrayByNaturalName $xml (@($desiredFiles)) }
    $desired = @($desiredDirs + $desiredFiles)
  }

  # Compare current vs desired by reference order
  $current = $kids
  $changed = $false
  for ($i=0; $i -lt $current.Count; $i++) {
    if (-not [object]::ReferenceEquals($current[$i], $desired[$i])) { $changed = $true; break }
  }

  # Reorder in XML while keeping non-eligible nodes (non-media, etc.) in place
  if ($changed) {
    $desiredIndex = 0
    $newNodes = @()
    foreach ($n in $allNodes) {
      if (Should-ConsiderNodeForSort $xml $n $sortScope $fileFilter) {
        $newNodes += $desired[$desiredIndex]
        $desiredIndex++
      } else {
        $newNodes += $n
      }
    }

    foreach ($n in $allNodes) { [void]$parentNode.RemoveChild($n) }
    foreach ($n in $newNodes) { [void]$parentNode.AppendChild($n) }
  }

  # Reassign order attributes for all file/directory siblings (match final XML order)
  $siblings = @($parentNode.ChildNodes | Where-Object {
    $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and ($_.Name -eq "directory" -or $_.Name -eq "file")
  })
  for ($i=0; $i -lt $siblings.Count; $i++) {
    $newOrder = [string](($i+1) * 100)
    if ($siblings[$i].GetAttribute("order") -ne $newOrder) {
      $siblings[$i].SetAttribute("order", $newOrder)
      $changed = $true
    }
  }

  return $changed
}

function Walk-Sort([xml]$xml, $node, [string]$sortScope, [string]$fileFilter) {
  $any = $false
  if (Sort-Siblings $xml $node $sortScope $fileFilter) { $any = $true }

  foreach ($child in @($node.ChildNodes)) {
    if ($child.Name -eq "directory" -and -not (Should-SkipNode $xml $child)) {
      if (Walk-Sort $xml $child $sortScope $fileFilter) { $any = $true }
    }
  }
  return $any
}

function Walk-Check([xml]$xml, $node, [string]$path, [string]$sortScope, [string]$fileFilter, [ref]$messages) {
  $ok = $true

  # Children we consider (respect scope + file filter)
  $kids = @()
  foreach ($child in @($node.ChildNodes)) {
    if (Should-ConsiderNodeForSort $xml $child $sortScope $fileFilter) {
      $kids += $child
    }
  }

  if ($kids.Count -gt 0) {
    # Actual order by appearance
    $actual = $kids | ForEach-Object {
      $t = if (Is-DirectoryNode $_) { "D" } else { "F" }
      "${t}:" + (Get-Name $xml $_)
    }

    # Expected order
    $expectedKids = @()
    if ($sortScope -eq "FoldersOnly" -or $sortScope -eq "FilesOnly") {
      $expectedKids = Sort-ArrayByNaturalName $xml (@($kids))
    } else {
      $dirs = @(); $files = @()
      foreach ($k in $kids) { if (Is-DirectoryNode $k) { $dirs += $k } else { $files += $k } }
      if ($dirs.Count -gt 0) { $dirs = Sort-ArrayByNaturalName $xml (@($dirs)) }
      if ($files.Count -gt 0) { $files = Sort-ArrayByNaturalName $xml (@($files)) }
      $expectedKids = @($dirs + $files)
    }

    $expected = $expectedKids | ForEach-Object {
      $t = if (Is-DirectoryNode $_) { "D" } else { "F" }
      "${t}:" + (Get-Name $xml $_)
    }

    if (-not (($actual -join "`n").Equals($expected -join "`n"))) {
      $ok = $false
      $messages.Value += "NOT_SORTED at $path"
      $messages.Value += "  ACTUAL  : " + ($actual -join " | ")
      $messages.Value += "  EXPECTED: " + ($expected -join " | ")
    }
  }

  # Recurse into directories (excluding skip)
  foreach ($child in @($node.ChildNodes)) {
    if ($child.Name -eq "directory" -and -not (Should-SkipNode $xml $child)) {
      $childName = Get-Name $xml $child
      $childPath = if ($path -eq "/root") { "/root/$childName" } else { "$path/$childName" }
      $childOk = Walk-Check $xml $child $childPath $sortScope $fileFilter $messages
      if (-not $childOk) { $ok = $false }
    }
  }

  return $ok
}

if ($PSCmdlet.ParameterSetName -eq "Help") {
  Show-ScriptHelp
  exit 0
}

if ($PSCmdlet.ParameterSetName -eq "InstallYafs") {
  try {
    Install-YafsBinaries $YafsPath $YafsSourceDir
    exit 0
  } catch {
    Write-Host ("ERROR: " + $_.Exception.Message)
    exit 4
  }
}

$devicesParsed = Parse-DeviceList $Device
if ($devicesParsed.Count -eq 0) {
  Write-Host "ERROR: no valid drive letter parsed from -Device (example: -Device 'f:' or -Device 'f:,g:')"
  exit 4
}

$validDevices = @()
$skippedDevices = @()
foreach ($d in $devicesParsed) {
  if (Test-DeviceReady $d) { $validDevices += $d } else { $skippedDevices += $d }
}
foreach ($d in $skippedDevices) {
  Write-Host ("SKIP: {0} (not found / not ready)" -f $d)
}
if ($validDevices.Count -eq 0) {
  Write-Host "ERROR: no valid/ready drives to process"
  exit 4
}

if ($validDevices.Count -gt 1) {
  $pwshExe = Get-SelfPowerShellExe
  $scriptPath = $PSCommandPath
  $exitCode = Invoke-MultiDeviceRun -devices $validDevices -pwshExe $pwshExe -scriptPath $scriptPath -yafsPath $YafsPath -mode $Mode -sortScope $SortScope -fileFilter $FileFilter -treeOutBase $TreeOut -sortedTreeOutBase $SortedTreeOut -treeIn $TreeIn -force:$Force -verboseLog:$VerboseLog -noParallel:$NoParallel -throttleLimit $ThrottleLimit
  exit $exitCode
}

$deviceSingle = $validDevices[0]

try {
  Test-Executable $YafsPath

  # Mode: SortOnlyFromTree (apply a given tree file)
  if ($Mode -eq "SortOnlyFromTree") {
    $inFile = if ($TreeIn) { $TreeIn } else { $SortedTreeOut }
    if (-not (Test-Path -LiteralPath $inFile)) { throw "TreeIn not found: $inFile" }

    if (-not $Force) {
      if (-not (Confirm-Apply $deviceSingle $inFile)) {
        Write-Host "CANCELLED"
        exit 3
      }
    }

    Invoke-YafsWrite $YafsPath $deviceSingle $inFile
    Write-Host "SORTED_APPLIED"
    exit 2
  }

  # For other modes, dump current tree first
  Invoke-YafsRead $YafsPath $deviceSingle $TreeOut
  $xml = Load-Xml $TreeOut
  $root = $xml.DocumentElement
  if ($null -eq $root) { throw "Invalid XML: missing root element" }

  # CHECK
  $msgs = @()
  $ok = Walk-Check $xml $root "/root" $SortScope $FileFilter ([ref]$msgs)

  if ($Mode -eq "CheckOnly") {
    if ($ok) {
      Write-Host "OK"
      exit 0
    } else {
      $msgs | Select-Object -First 50 | ForEach-Object { Write-Host $_ }
      Write-Host "NG"
      exit 1
    }
  }

  if ($Mode -eq "SortOnlyAuto") {
    [void](Walk-Sort $xml $root $SortScope $FileFilter)
    Save-Xml $xml $SortedTreeOut

    if (-not $Force) {
      if (-not (Confirm-Apply $deviceSingle $SortedTreeOut)) {
        Write-Host "CANCELLED"
        exit 3
      }
    }

    Invoke-YafsWrite $YafsPath $deviceSingle $SortedTreeOut
    Write-Host "SORTED_APPLIED"
    exit 2
  }

  if ($Mode -eq "CheckAndSort") {
    if ($ok) {
      Write-Host "OK"
      exit 0
    }

    # Not sorted -> sort + apply
    [void](Walk-Sort $xml $root $SortScope $FileFilter)
    Save-Xml $xml $SortedTreeOut

    if (-not $Force) {
      if (-not (Confirm-Apply $deviceSingle $SortedTreeOut)) {
        Write-Host "CANCELLED"
        exit 3
      }
    }

    Invoke-YafsWrite $YafsPath $deviceSingle $SortedTreeOut

    # Verify
    Invoke-YafsRead $YafsPath $deviceSingle $TreeOut
    $xml2 = Load-Xml $TreeOut
    $msgs2 = @()
    $ok2 = Walk-Check $xml2 $xml2.DocumentElement "/root" $SortScope $FileFilter ([ref]$msgs2)

    if ($ok2) {
      Write-Host "SORTED_APPLIED_OK"
      exit 2
    } else {
      $msgs2 | Select-Object -First 50 | ForEach-Object { Write-Host $_ }
      Write-Host "ERROR_VERIFY_FAIL"
      exit 4
    }
  }

  throw "Unknown mode: $Mode"
}
catch {
  Write-Host ("ERROR: " + $_.Exception.Message)
  exit 4
}
