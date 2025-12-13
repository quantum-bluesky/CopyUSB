<#
UsbWslMount.ps1 (FINAL + PROBE)

Actions:
  - List:    Show usbipd devices + WSL distros
  - Probe:   Auto-detect BUSID by diffing usbipd list before/after (you unplug/plug target USB)
  - Mount:   Bind + attach a USB device to WSL2, detect new /dev/sdX, mount first partition to MountPoint
  - Unmount: Unmount in WSL, detach from Windows, optional unbind

Supports:
  -DriveLetter F (or F:) OR -BusId 2-1
  Multiple USBs: prompts selection safely OR use -AutoProbe / -Action Probe.

Prereqs:
  Windows (Admin PowerShell):
    - WSL2 installed
    - usbipd-win installed (usbipd.exe in PATH)  -> winget install usbipd

  Linux inside WSL distro:
    - util-linux (lsblk, mountpoint)
    - mount/umount
    - dosfstools (for vfat) / exfatprogs (for exfat) recommended

Exit codes:
  0 OK
  1 Missing tool/prereq
  2 User action required / ambiguous / no block device found
  3 Mount/Unmount failure
  4 usbipd bind/attach/detach failure or unexpected error
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [ValidateSet("List","Probe","Mount","Unmount")]
  [string]$Action,

  # Provide either DriveLetter or BusId
  [string]$DriveLetter,
  [string]$BusId,

  # Use Probe automatically when resolving BusId (recommended when multiple USBs exist)
  [switch]$AutoProbe,

  # Probe behavior: what you will do when prompted
  # Plug  : you will PLUG IN the target USB after the first snapshot
  # Unplug: you will UNPLUG the target USB after the first snapshot
  [ValidateSet("Plug","Unplug")]
  [string]$ProbeMode = "Plug",

  # Optional: WSL distro name (wsl -l -v). If omitted, uses default/first.
  [string]$Distro,

  # Linux mount point inside WSL
  [string]$MountPoint = "/mnt/usb",

  # Filesystem hint (auto is usually fine)
  [ValidateSet("auto","vfat","exfat","ntfs")]
  [string]$FsType = "auto",

  # After Unmount: unbind device (set back to Not shared). Some usbipd builds may not support; ignored if fails.
  [switch]$Unbind,

  # Probe output only the BUSID (useful for scripting)
  [switch]$Quiet,

  [switch]$VerboseLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log([string]$msg) { if ($VerboseLog) { Write-Host $msg } }
function Write-Info([string]$msg) { if (-not $Quiet) { Write-Host $msg } }
function Write-Warn([string]$msg) { if (-not $Quiet) { Write-Host "WARN: $msg" } }
function Write-Err ([string]$msg) { Write-Host "ERROR: $msg" }

function Show-PrereqHints {
  Write-Info ""
  Write-Info "Prerequisites / Install hints:"
  Write-Info "Windows:"
  Write-Info "  - Install usbipd-win:  winget install usbipd"
  Write-Info "  - Ensure WSL2:         wsl -l -v"
  Write-Info ""
  Write-Info "Linux (inside WSL distro):"
  Write-Info "  - Ubuntu/Debian: sudo apt update && sudo apt install -y util-linux dosfstools exfatprogs"
  Write-Info "  - (util-linux provides lsblk + mountpoint; dosfstools=vfat; exfatprogs=exfat)"
  Write-Info ""
}

function Require-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Please run PowerShell as Administrator."
  }
}

function Require-Cmd($name, $hint) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    Write-Err "Missing tool: $name"
    Write-Info $hint
    exit 1
  }
}

function Normalize-DriveLetter([string]$dl) {
  if (-not $dl) { return $null }
  $dl = $dl.Trim()
  if ($dl.EndsWith(":")) { $dl = $dl.Substring(0, $dl.Length-1) }
  if ($dl.Length -ne 1) { return $null }
  return $dl.ToUpperInvariant()
}

function Get-DefaultDistro {
  $names = & wsl.exe -l -q 2>$null
  if (-not $names) { return $null }
  return ($names | Select-Object -First 1).Trim()
}

function Run-InWsl([string]$distro, [string]$bashCmd) {
  if ($distro) {
    return & wsl.exe -d $distro -- bash -lc $bashCmd
  } else {
    return & wsl.exe -- bash -lc $bashCmd
  }
}

function Ensure-Linux-Tools([string]$distro) {
  $cmd = @"
command -v lsblk >/dev/null 2>&1 || echo MISSING_LSBLK;
command -v mount >/dev/null 2>&1 || echo MISSING_MOUNT;
command -v umount >/dev/null 2>&1 || echo MISSING_UMOUNT;
command -v mountpoint >/dev/null 2>&1 || echo MISSING_MOUNTPOINT;
"@
  $out = Run-InWsl $distro $cmd
  if ($out -match "MISSING_") {
    Write-Err "Missing Linux tools inside WSL distro: $out"
    Show-PrereqHints
    exit 1
  }
}

function Usbipd-ListRaw { & usbipd.exe list }

function Get-UsbipdDevices {
  $out = Usbipd-ListRaw
  $rows = @()
  foreach ($line in $out) {
    if ($line -match '^\s*(\S+)\s+([0-9a-fA-F:]+)\s+(.+?)\s{2,}(Shared|Not shared)') {
      $rows += [pscustomobject]@{
        BusId  = $matches[1]
        VidPid = $matches[2]
        Name   = $matches[3].Trim()
        State  = $matches[4]
      }
    }
  }
  return $rows
}

function Get-UsbInfoFromDriveLetter([string]$driveLetter) {
  $dl = Normalize-DriveLetter $driveLetter
  if (-not $dl) { throw "Invalid DriveLetter: $driveLetter" }

  $part = Get-Partition -DriveLetter $dl -ErrorAction Stop
  $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop

  return [pscustomobject]@{
    DriveLetter = "${dl}:"
    DiskNumber  = $disk.Number
    BusType     = $disk.BusType
    Friendly    = $disk.FriendlyName
    Serial      = $disk.SerialNumber
    Location    = $disk.LocationPath
    PnpId       = $disk.PnpDeviceID
  }
}

function Pick-FromList($items, [string]$prompt) {
  for ($i=0; $i -lt $items.Count; $i++) {
    $it = $items[$i]
    Write-Host "[$i] BUSID=$($it.BusId)  NAME=$($it.Name)  STATE=$($it.State)"
  }
  $sel = Read-Host $prompt
  if ($sel -notmatch '^\d+$') { throw "Invalid selection" }
  $idx = [int]$sel
  if ($idx -lt 0 -or $idx -ge $items.Count) { throw "Invalid selection index" }
  return $items[$idx]
}

function Probe-BusId([string]$mode) {
  $before = Get-UsbipdDevices
  if (-not $Quiet) {
    Write-Info "Probe snapshot taken."
    if ($mode -eq "Plug") {
      Write-Info "Now PLUG IN the target USB device, then press ENTER."
    } else {
      Write-Info "Now UNPLUG the target USB device, then press ENTER."
    }
    [void](Read-Host "")
  }

  $after = Get-UsbipdDevices

  $beforeIds = @{}
  foreach ($b in $before) { $beforeIds[$b.BusId] = $b }

  $afterIds = @{}
  foreach ($a in $after) { $afterIds[$a.BusId] = $a }

  $diff = @()

  if ($mode -eq "Plug") {
    # New BUSIDs present after but not before
    foreach ($k in $afterIds.Keys) {
      if (-not $beforeIds.ContainsKey($k)) {
        $diff += $afterIds[$k]
      }
    }
  } else {
    # Removed BUSIDs present before but not after
    foreach ($k in $beforeIds.Keys) {
      if (-not $afterIds.ContainsKey($k)) {
        $diff += $beforeIds[$k]
      }
    }
  }

  if ($diff.Count -eq 1) {
    return $diff[0].BusId
  }

  if ($diff.Count -eq 0) {
    Write-Err "Probe failed: no device change detected. Try again, or use -BusId directly."
    return $null
  }

  Write-Warn "Probe found multiple device changes. Please pick the correct one:"
  $picked = Pick-FromList $diff "Select device index"
  return $picked.BusId
}

function Resolve-BusId {
  if ($BusId) { return $BusId }

  if ($AutoProbe) {
    $p = Probe-BusId $ProbeMode
    if (-not $p) { exit 2 }
    if ($Quiet) { Write-Host $p } else { Write-Info "Resolved BUSID via Probe: $p" }
    return $p
  }

  if (-not $DriveLetter) {
    throw "You must provide either -BusId, or -DriveLetter, or use -AutoProbe."
  }

  $info = Get-UsbInfoFromDriveLetter $DriveLetter
  Write-Info "Drive $($info.DriveLetter) -> Disk #$($info.DiskNumber), BusType=$($info.BusType)"
  Write-Info "Disk Friendly=$($info.Friendly)"
  Write-Log  "Disk PNP ID = $($info.PnpId)"
  Write-Log  "Disk LocationPath = $($info.Location)"
  Write-Info ""

  $usbipd = Get-UsbipdDevices

  # Filter to likely storage devices (best-effort)
  $candidates = $usbipd | Where-Object {
    $_.Name -match 'Mass Storage|CardReader|Reader|USB Mass|Storage|SD|microSD' -or
    $_.VidPid -match '^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$'
  }

  if ($candidates.Count -eq 0) {
    Write-Err "No candidate USB devices found in usbipd list."
    Write-Info (Usbipd-ListRaw | Out-String)
    exit 2
  }

  if ($candidates.Count -eq 1) {
    Write-Info "Auto-selected BUSID: $($candidates[0].BusId)"
    return $candidates[0].BusId
  }

  Write-Warn "Multiple USB candidates detected."
  Write-Info  "Tip: Use -AutoProbe to auto-resolve BUSID by plug/unplug diff."
  $picked = Pick-FromList $candidates "Select device index"
  Write-Info "Selected BUSID: $($picked.BusId)"
  return $picked.BusId
}

function Get-LsblkDisks([string]$distro) {
  # Escape $ for awk as \$ (PowerShell string)
  $cmd = "lsblk -ndo NAME,TYPE | awk '\$2==""disk""{print \$1}'"
  $out = Run-InWsl $distro $cmd
  return @($out | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Find-NewDisk([string[]]$before, [string[]]$after) {
  $set = @{}
  foreach ($b in $before) { $set[$b] = $true }
  return @($after | Where-Object { -not $set.ContainsKey($_) })
}

function Get-FirstPartition([string]$distro, [string]$diskName) {
  $cmd = "lsblk -ndo NAME,TYPE /dev/$diskName | awk '\$2==""part""{print \$1; exit}'"
  $p = Run-InWsl $distro $cmd
  $p = ($p | Select-Object -First 1).Trim()
  return $p
}

function Detect-Fstype([string]$distro, [string]$partName) {
  $cmd = "lsblk -ndo FSTYPE /dev/$partName | head -n 1"
  $fs = Run-InWsl $distro $cmd
  return ($fs | Select-Object -First 1).Trim()
}

function Linux-Mount([string]$distro, [string]$partName, [string]$mountPoint, [string]$fsType) {
  $mpEsc = $mountPoint.Replace("'", "'\''")
  $fs = $fsType
  if ($fs -eq "auto") {
    $det = Detect-Fstype $distro $partName
    if ($det) { $fs = $det } else { $fs = "auto" }
  }

  $opts = ""
  if ($fs -match "vfat|fat|msdos") { $opts = "-t vfat -o uid=1000,gid=1000,umask=022" }
  elseif ($fs -match "exfat")      { $opts = "-t exfat -o uid=1000,gid=1000,umask=022" }
  else { $opts = "" } # auto

  $cmd = @"
sudo mkdir -p '${mpEsc}' &&
sudo mount $opts /dev/${partName} '${mpEsc}' &&
echo MOUNT_OK
"@
  $out = Run-InWsl $distro $cmd
  if ($out -notmatch "MOUNT_OK") {
    throw "Mount failed. Output: $out"
  }
}

function Linux-Umount([string]$distro, [string]$mountPoint) {
  $mpEsc = $mountPoint.Replace("'", "'\''")
  $cmd = @"
if mountpoint -q '${mpEsc}'; then
  sudo umount '${mpEsc}' && echo UMOUNT_OK
else
  echo UMOUNT_NOT_MOUNTED
fi
"@
  return Run-InWsl $distro $cmd
}

# ===================== MAIN =====================
try {
  Require-Admin
  Require-Cmd "usbipd.exe" "Install usbipd-win:  winget install usbipd"
  Require-Cmd "wsl.exe"    "Install WSL:         wsl --install"

  if (-not $Distro) {
    $Distro = Get-DefaultDistro
    if (-not $Distro) {
      Write-Err "No WSL distro found. Run: wsl --install"
      exit 1
    }
  }

  if ($Action -eq "List") {
    Write-Info "usbipd list:"
    Usbipd-ListRaw | Write-Host
    Write-Info ""
    Write-Info "WSL distros:"
    & wsl.exe -l -v | Write-Host
    exit 0
  }

  if ($Action -eq "Probe") {
    $p = Probe-BusId $ProbeMode
    if (-not $p) { exit 2 }
    if ($Quiet) { Write-Host $p } else { Write-Info "BUSID: $p" }
    exit 0
  }

  Ensure-Linux-Tools $Distro

  $resolvedBusId = Resolve-BusId

  if ($Action -eq "Mount") {
    $before = Get-LsblkDisks $Distro

    & usbipd.exe bind --busid $resolvedBusId | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Err "usbipd bind failed (code $LASTEXITCODE)"; exit 4 }

    & usbipd.exe attach --busid $resolvedBusId --wsl --distribution $Distro | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Err "usbipd attach failed (code $LASTEXITCODE)"; exit 4 }

    Start-Sleep -Milliseconds 600

    $after = Get-LsblkDisks $Distro
    $newDisks = Find-NewDisk $before $after

    if ($newDisks.Count -lt 1) {
      Write-Err "USB attached but no new /dev/sdX disk appeared in WSL."
      Write-Info "Diagnostics inside WSL:"
      Write-Info "  lsusb"
      Write-Info "  dmesg | tail -50"
      Write-Warn "Some USB MP3/card-reader devices do not expose a standard Linux block device."
      exit 2
    }

    $disk = $newDisks[0]
    $part = Get-FirstPartition $Distro $disk
    if (-not $part) {
      Write-Err "New disk /dev/$disk found but no partition detected."
      Write-Info "Try inside WSL: lsblk /dev/$disk"
      exit 3
    }

    Linux-Mount $Distro $part $MountPoint $FsType
    Write-Info "OK: Mounted /dev/$part to $MountPoint in WSL distro '$Distro'."
    Write-Info "BUSID $resolvedBusId is attached to WSL (Windows can't use it until detached)."
    exit 0
  }

  if ($Action -eq "Unmount") {
    $u = Linux-Umount $Distro $MountPoint
    if ($u -match "UMOUNT_OK") { Write-Info "OK: Unmounted $MountPoint in WSL." }
    elseif ($u -match "UMOUNT_NOT_MOUNTED") { Write-Warn "$MountPoint not mounted (continuing detach)." }
    else { Write-Warn "Unmount output: $u" }

    & usbipd.exe detach --busid $resolvedBusId | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Err "usbipd detach failed (code $LASTEXITCODE)"; exit 4 }

    if ($Unbind) {
      & usbipd.exe unbind --busid $resolvedBusId 2>$null | Out-Null
    }

    Write-Info "OK: Detached BUSID $resolvedBusId from WSL. USB should be usable in Windows again."
    exit 0
  }

  throw "Unknown Action: $Action"
}
catch {
  Write-Err $_.Exception.Message
  Show-PrereqHints
  exit 4
}
