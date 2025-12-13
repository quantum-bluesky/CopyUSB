<#
Mp3FatSort.ps1 - FAT directory order checker/sorter using YAFS (XML tree)

Features
- Uses YAFS to read/write FAT directory order via XML tree:
    yafs -d e: -r -f tree.xml
    yafs -d e: -w -f tree_sorted.xml
- Skip:
    * Directory: "System Volume Information"
    * File     : "desktop.ini"
- Sort by "long file name" (long_name), fallback short_name
- Natural sort (01,02,03,...,10,11,...) with case-insensitive compare
- Sort scope options:
    * Both        : sort <directory> + <file> siblings at each level (dir-first)
    * FoldersOnly : only sort directories; keep file order as-is
    * FilesOnly   : only sort files; keep folder order as-is

Modes
- CheckOnly        : read device, check sorted status (no write)
- SortOnlyAuto     : read device, generate sorted tree, write to device
- SortOnlyFromTree : write a provided tree file to device (no read/check unless you do it)
- CheckAndSort     : read device, check; if NG then sort+write; verify again

Exit codes
  0 = OK (already sorted / check pass)
  1 = NG (not sorted) [used for CheckOnly]
  2 = SORTED (changes applied to device)
  3 = CANCELLED (user chose No at confirm)
  4 = ERROR (unexpected failure, verify fail, yafs failure, etc.)

Examples
  # Check folders + files
  .\Mp3FatSort.ps1 -YafsPath "C:\Tools\yafs\yafs.exe" -Device "e:" -Mode CheckOnly

  # Check & auto-fix (no confirm)
  .\Mp3FatSort.ps1 -YafsPath "C:\Tools\yafs\yafs.exe" -Device "e:" -Mode CheckAndSort -Force

  # Only sort folders, keep file order inside
  .\Mp3FatSort.ps1 -YafsPath "C:\Tools\yafs\yafs.exe" -Device "e:" -Mode CheckAndSort -SortScope FoldersOnly -Force

  # Only sort files, keep folder order
  .\Mp3FatSort.ps1 -YafsPath "C:\Tools\yafs\yafs.exe" -Device "e:" -Mode CheckAndSort -SortScope FilesOnly -Force

  # Apply a prepared tree file
  .\Mp3FatSort.ps1 -YafsPath "C:\Tools\yafs\yafs.exe" -Device "e:" -Mode SortOnlyFromTree -TreeIn ".\tree_sorted.xml" -Force
#>

[CmdletBinding()]
param(
  # YAFS exe path
  [string]$YafsPath="C:\Tools\yafs\yafs.exe",

  # Drive letter like "e:" (exactly as YAFS expects)
  [Parameter(Mandatory=$true)]
  [ValidatePattern('^[A-Za-z]:$')]
  [string]$Device,

  # Mode
  [Parameter(Mandatory=$true)]
  [ValidateSet("CheckOnly","SortOnlyAuto","SortOnlyFromTree","CheckAndSort")]
  [string]$Mode,

  # Sort scope
  # - Both        : sort directory + file at every level (default)
  # - FoldersOnly : only sort <directory> siblings; keep <file> order as-is
  # - FilesOnly   : only sort <file> siblings; keep <directory> order as-is
  [ValidateSet("Both","FoldersOnly","FilesOnly")]
  [string]$SortScope = "Both",

  # File filtering
  # Default: only sort/check media files (audio/video). Non-media files are ignored.
  [ValidateSet("MediaOnly","AllFiles")]
  [string]$FileFilter = "MediaOnly",

  # Where to dump current tree (from yafs -r). Default: .\tree.xml
  [string]$TreeOut = (Join-Path (Get-Location) "tree.xml"),

  # Where to write sorted tree xml. Default: .\tree_sorted.xml
  [string]$SortedTreeOut = (Join-Path (Get-Location) "tree_sorted.xml"),

  # Tree file to apply (for SortOnlyFromTree). If omitted, use -SortedTreeOut
  [string]$TreeIn,

  # Confirm before writing to device (unless -Force)
  [switch]$Force,

  # Verbose-ish logging
  [switch]$VerboseLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log([string]$msg) {
  if ($VerboseLog) { Write-Host $msg }
}

function Test-Executable([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) {
    throw "YAFS not found: $path"
  }
}

function Invoke-YafsRead([string]$yafs, [string]$device, [string]$outFile) {
  Write-Log "Running: $yafs -d $device -r -f `"$outFile`""
  & $yafs -d $device -r -f $outFile | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "yafs -r failed with code $LASTEXITCODE" }
}

function Invoke-YafsWrite([string]$yafs, [string]$device, [string]$inFile) {
  Write-Log "Running: $yafs -d $device -w -f `"$inFile`""
  & $yafs -d $device -w -f $inFile | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "yafs -w failed with code $LASTEXITCODE" }
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

try {
  Test-Executable $YafsPath

  # Mode: SortOnlyFromTree (apply a given tree file)
  if ($Mode -eq "SortOnlyFromTree") {
    $inFile = if ($TreeIn) { $TreeIn } else { $SortedTreeOut }
    if (-not (Test-Path -LiteralPath $inFile)) { throw "TreeIn not found: $inFile" }

    if (-not $Force) {
      if (-not (Confirm-Apply $Device $inFile)) {
        Write-Host "CANCELLED"
        exit 3
      }
    }

    Invoke-YafsWrite $YafsPath $Device $inFile
    Write-Host "SORTED_APPLIED"
    exit 2
  }

  # For other modes, dump current tree first
  Invoke-YafsRead $YafsPath $Device $TreeOut
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
      if (-not (Confirm-Apply $Device $SortedTreeOut)) {
        Write-Host "CANCELLED"
        exit 3
      }
    }

    Invoke-YafsWrite $YafsPath $Device $SortedTreeOut
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
      if (-not (Confirm-Apply $Device $SortedTreeOut)) {
        Write-Host "CANCELLED"
        exit 3
      }
    }

    Invoke-YafsWrite $YafsPath $Device $SortedTreeOut

    # Verify
    Invoke-YafsRead $YafsPath $Device $TreeOut
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
