<#
Mp3FatSort.ps1 - FAT directory order checker/sorter using YAFS (XML tree)
- Skip: "System Volume Information" directory, and "desktop.ini" file
- Sort rule: dir-first, natural sort by long_name (fallback short_name)
- Modes:
  - CheckOnly
  - SortOnlyAuto
  - SortOnlyFromTree
  - CheckAndSort (auto, with confirmation unless -Force)

Exit codes:
  0 = OK (already sorted / check pass)
  1 = NG (not sorted)  [used for CheckOnly]
  2 = SORTED (changes applied to device)
  3 = CANCELLED (user chose No at confirm)
  4 = ERROR (unexpected failure)
#>

[CmdletBinding(DefaultParameterSetName="CheckOnly")]
param(
  # YAFS exe path
  [Parameter(Mandatory=$true)]
  [string]$YafsPath,

  # Drive letter like "e:" (exactly as YAFS expects)
  [Parameter(Mandatory=$true)]
  [ValidatePattern('^[A-Za-z]:$')]
  [string]$Device,

  # Mode
  [Parameter(Mandatory=$true)]
  [ValidateSet("CheckOnly","SortOnlyAuto","SortOnlyFromTree","CheckAndSort")]
  [string]$Mode,

  # Where to dump current tree (from yafs -r). Default: .\tree.xml
  [string]$TreeOut = (Join-Path (Get-Location) "tree.xml"),

  # Where to write sorted tree xml. Default: .\tree_sorted.xml
  [string]$SortedTreeOut = (Join-Path (Get-Location) "tree_sorted.xml"),

  # Tree file to apply (for SortOnlyFromTree). If omitted, use -SortedTreeOut
  [string]$TreeIn,

  # Confirm before writing to device (used by CheckAndSort unless -Force)
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

function Get-Name([xml]$xml, $node) {
  # Prefer long_name, fallback to short_name
  $ln = $node.long_name
  if ($null -ne $ln -and "$ln".Trim().Length -gt 0) { return "$ln".Trim() }
  $sn = $node.short_name
  if ($null -ne $sn -and "$sn".Trim().Length -gt 0) { return "$sn".Trim() }
  return ""
}

function Is-DirectoryNode($node) { return $node.Name -eq "directory" }
function Is-FileNode($node) { return $node.Name -eq "file" }

function Should-SkipNode([xml]$xml, $node) {
  if (Is-DirectoryNode $node) {
    $n = Get-Name $xml $node
    if ($n -ieq "System Volume Information") { return $true }
  }
  if (Is-FileNode $node) {
    # desktop.ini sometimes has only short_name; compare both
    $n = Get-Name $xml $node
    if ($n -ieq "desktop.ini") { return $true }
  }
  return $false
}

function Natural-KeyParts([string]$s) {
  # Return array of parts: numbers as [int], others as lowercase string
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

function Sort-Siblings([xml]$xml, $parentNode) {
  # Get children nodes (directory/file) excluding skips
  $kids = @()
  foreach ($child in @($parentNode.ChildNodes)) {
    if (($child.Name -eq "directory" -or $child.Name -eq "file") -and -not (Should-SkipNode $xml $child)) {
      $kids += $child
    }
  }
  if ($kids.Count -eq 0) { return $false }

  $getSortKey = {
    param($n)
    $typeRank = if (Is-DirectoryNode $n) { 0 } else { 1 }   # dir first
    $name = Get-Name $xml $n
    return @{ typeRank=$typeRank; name=$name }
  }

  # Current order list (by appearance, not attribute)
  $current = $kids

  # Desired order using natural compare on name, stable
  $desired = $kids | Sort-Object `
    @{Expression = { (& $getSortKey $_).typeRank }}, `
    @{Expression = { (& $getSortKey $_).name }; Ascending=$true } `
    -Stable

  # BUT Sort-Object is lexicographic, not natural. We'll do custom natural sort:
  $desired = $kids | Sort-Object -Stable -Property @{ Expression = {
      $k = & $getSortKey $_
      # create a string key for primary sort (typeRank) + name
      # We will refine tie-breaking with custom natural compare below by using a second pass
      "{0}|{1}" -f $k.typeRank, $k.name
    } }
  # Second pass: custom natural inside same typeRank
  $desired = $desired | Group-Object { if (Is-DirectoryNode $_) { 0 } else { 1 } } | ForEach-Object {
    $_.Group | Sort-Object -Stable -Property @{ Expression = { Get-Name $xml $_ } } | ForEach-Object { $_ }
  }

  # Custom natural compare within each group (replace above lexicographic)
  $final = New-Object System.Collections.Generic.List[object]
  foreach ($grp in ($kids | Group-Object { if (Is-DirectoryNode $_) { 0 } else { 1 } } | Sort-Object Name)) {
    $arr = @($grp.Group)
    # simple insertion sort with Compare-Natural
    for ($i=1; $i -lt $arr.Count; $i++) {
      $tmp = $arr[$i]
      $j = $i - 1
      while ($j -ge 0 -and (Compare-Natural (Get-Name $xml $arr[$j]) (Get-Name $xml $tmp)) -gt 0) {
        $arr[$j+1] = $arr[$j]
        $j--
      }
      $arr[$j+1] = $tmp
    }
    foreach ($n in $arr) { $final.Add($n) | Out-Null }
  }
  $desired = @($final)

  $changed = $false

  # Compare current vs desired by reference order
  for ($i=0; $i -lt $current.Count; $i++) {
    if (-not [object]::ReferenceEquals($current[$i], $desired[$i])) {
      $changed = $true
      break
    }
  }

  # Reorder in XML by removing + appending (only the non-skipped nodes)
  if ($changed) {
    foreach ($n in $current) { [void]$parentNode.RemoveChild($n) }
    foreach ($n in $desired) { [void]$parentNode.AppendChild($n) }
  }

  # Reassign order attributes 100,200,300... for desired nodes
  for ($i=0; $i -lt $desired.Count; $i++) {
    $newOrder = [string](($i+1) * 100)
    if ($desired[$i].GetAttribute("order") -ne $newOrder) {
      $desired[$i].SetAttribute("order", $newOrder)
      $changed = $true
    }
  }

  return $changed
}

function Walk-Sort([xml]$xml, $node) {
  $any = $false
  if (Sort-Siblings $xml $node) { $any = $true }

  # Walk directories (including ones we skip? We skip sorting inside SVI by skipping the node itself)
  foreach ($child in @($node.ChildNodes)) {
    if ($child.Name -eq "directory" -and -not (Should-SkipNode $xml $child)) {
      if (Walk-Sort $xml $child) { $any = $true }
    }
  }
  return $any
}

function Walk-Check([xml]$xml, $node, [string]$path, [ref]$messages) {
  $ok = $true

  # children we consider
  $kids = @()
  foreach ($child in @($node.ChildNodes)) {
    if (($child.Name -eq "directory" -or $child.Name -eq "file") -and -not (Should-SkipNode $xml $child)) {
      $kids += $child
    }
  }

  if ($kids.Count -gt 0) {
    # actual order (by appearance)
    $actual = $kids | ForEach-Object {
      $t = if (Is-DirectoryNode $_) { "D" } else { "F" }
      "$t:" + (Get-Name $xml $_)
    }

    # expected: dir-first then natural by name
    $expectedKids = @()

    foreach ($grp in ($kids | Group-Object { if (Is-DirectoryNode $_) { 0 } else { 1 } } | Sort-Object Name)) {
      $arr = @($grp.Group)
      # insertion sort by natural
      for ($i=1; $i -lt $arr.Count; $i++) {
        $tmp = $arr[$i]; $j = $i - 1
        while ($j -ge 0 -and (Compare-Natural (Get-Name $xml $arr[$j]) (Get-Name $xml $tmp)) -gt 0) {
          $arr[$j+1] = $arr[$j]; $j--
        }
        $arr[$j+1] = $tmp
      }
      $expectedKids += $arr
    }

    $expected = $expectedKids | ForEach-Object {
      $t = if (Is-DirectoryNode $_) { "D" } else { "F" }
      "$t:" + (Get-Name $xml $_)
    }

    if (-not ($actual -join "`n").Equals($expected -join "`n")) {
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
      $childOk = Walk-Check $xml $child $childPath ([ref]$messages.Value)
      if (-not $childOk) { $ok = $false }
    }
  }

  return $ok
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

function Confirm-Apply([string]$device, [string]$file) {
  $q = "Apply sorted FAT order to device '$device' using tree file '$file'?"
  $ans = Read-Host "$q (Y/N)"
  return ($ans -match '^(y|yes)$')
}

try {
  Test-Executable $YafsPath

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

  # For other modes, we dump current tree first
  Invoke-YafsRead $YafsPath $Device $TreeOut
  $xml = Load-Xml $TreeOut

  # Root is <root> with children
  $root = $xml.DocumentElement
  if ($null -eq $root) { throw "Invalid XML: missing root element" }

  # CHECK
  $msgs = @()
  $ok = Walk-Check $xml $root "/root" ([ref]$msgs)

  if ($Mode -eq "CheckOnly") {
    if ($ok) {
      Write-Host "OK"
      exit 0
    } else {
      # show a limited amount to keep console readable
      $msgs | Select-Object -First 50 | ForEach-Object { Write-Host $_ }
      Write-Host "NG"
      exit 1
    }
  }

  if ($Mode -eq "SortOnlyAuto") {
    $changed = Walk-Sort $xml $root
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
    $changed = Walk-Sort $xml $root
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
    $ok2 = Walk-Check $xml2 $xml2.DocumentElement "/root" ([ref]$msgs2)

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
