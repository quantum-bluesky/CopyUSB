<#
Reset-UsbStorage.ps1
Purpose: Recover Windows USB storage visibility after usbipd/WSL experiments.

What it does:
  - Detach all usbipd-attached devices (release from WSL back to Windows)
  - Optional: Unbind (stop sharing) devices
  - Enable AutoMount + scrub old mount points
  - Ensure USBSTOR service is not Disabled
  - Print before/after snapshots

Run as: Administrator

Exit codes:
  0 OK
  1 Not admin / missing tool
  2 Failed to run diskpart/mountvol/registry changes
  3 usbipd operation failed
#>

[CmdletBinding()]
param(
  # Also run "usbipd unbind" on any devices that are Shared/Bound
  [switch]$AlsoUnbind,

  # Only operate on devices whose name contains these keywords (safer).
  # Example: -Filter "Mass Storage","CardReader"
  [string[]]$Filter = @("Mass Storage", "Storage", "CardReader", "Reader", "SD", "microSD")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Please run PowerShell as Administrator."
    exit 1
  }
}

function Require-Cmd($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Missing tool: $name"
    exit 1
  }
}

function Get-UsbipdDevices {
  $out = & usbipd.exe list
  $rows = @()
  foreach ($line in $out) {
    # Typical format:
    # BUSID  VID:PID    DEVICE                               STATE
    # 2-1    aaaa:8816  USB Mass Storage Device              Not shared
    if ($line -match '^\s*(\S+)\s+([0-9a-fA-F:]+)\s+(.+?)\s{2,}(Shared|Not shared)\s*$') {
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

function Match-Filter($name, $filterWords) {
  foreach ($w in $filterWords) {
    if ($name -like "*$w*") { return $true }
  }
  return $false
}

function Enable-AutoMount {
  # Use diskpart to enable automount and scrub stale mount points
  $script = @"
automount enable
automount scrub
exit
"@
  $tmp = Join-Path $env:TEMP ("diskpart_automount_{0}.txt" -f (Get-Random))
  Set-Content -LiteralPath $tmp -Value $script -Encoding ASCII

  try {
    Write-Host "Running diskpart automount enable/scrub..."
    & diskpart.exe /s $tmp | Out-Host
  }
  finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue | Out-Null
  }
}

function Ensure-USBSTOR-Enabled {
  $key = "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR"
  if (-not (Test-Path $key)) {
    Write-Host "WARN: USBSTOR registry key not found (unexpected). Skipping."
    return
  }

  $start = (Get-ItemProperty -Path $key -Name Start -ErrorAction Stop).Start
  Write-Host "USBSTOR Start currently: $start"
  if ($start -eq 4) {
    Write-Host "Fixing USBSTOR Start from 4 (Disabled) -> 3 (Manual)..."
    Set-ItemProperty -Path $key -Name Start -Type DWord -Value 3
    Write-Host "USBSTOR Start set to 3."
  }
}

# ===================== MAIN =====================
Require-Admin
Require-Cmd usbipd.exe
Require-Cmd diskpart.exe

Write-Host "=== BEFORE ==="
$before = Get-UsbipdDevices
if ($before.Count -gt 0) {
  $before | Format-Table -AutoSize | Out-Host
} else {
  Write-Host "(No parsable usbipd devices found from 'usbipd list' output.)"
}
Write-Host ""

# 1) Detach everything that looks like storage (safe filter)
$targets = $before | Where-Object { Match-Filter $_.Name $Filter }

if ($targets.Count -eq 0) {
  Write-Host "WARN: No usbipd devices matched filter: $($Filter -join ', ')"
  Write-Host "      If your device name is different, run: usbipd list"
} else {
  Write-Host "Detaching possible storage devices from WSL (releasing back to Windows)..."
  foreach ($t in $targets) {
    Write-Host " - detach BUSID=$($t.BusId) NAME=$($t.Name)"
    & usbipd.exe detach --busid $t.BusId | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Host "ERROR: usbipd detach failed for $($t.BusId) (code $LASTEXITCODE)"
      exit 3
    }
  }
}

# 2) Optional: unbind (stop sharing) to return to Not shared
if ($AlsoUnbind) {
  Write-Host "Unbinding (stop sharing) devices..."
  $afterDetach = Get-UsbipdDevices
  $targets2 = $afterDetach | Where-Object { Match-Filter $_.Name $Filter }
  foreach ($t in $targets2) {
    Write-Host " - unbind BUSID=$($t.BusId) NAME=$($t.Name)"
    & usbipd.exe unbind --busid $t.BusId 2>$null | Out-Null
    # Some versions may not support unbind; ignore if fails.
  }
}

# 3) Enable automount & scrub mount points
try {
  Enable-AutoMount
} catch {
  Write-Host "ERROR: Failed to run diskpart automount enable/scrub: $($_.Exception.Message)"
  exit 2
}

# 4) Ensure USBSTOR is enabled
try {
  Ensure-USBSTOR-Enabled
} catch {
  Write-Host "ERROR: Failed to inspect/modify USBSTOR: $($_.Exception.Message)"
  exit 2
}

Write-Host ""
Write-Host "=== AFTER ==="
$after = Get-UsbipdDevices
if ($after.Count -gt 0) {
  $after | Format-Table -AutoSize | Out-Host
} else {
  Write-Host "(No parsable usbipd devices found.)"
}

Write-Host ""
Write-Host "DONE."
Write-Host "Next steps:"
Write-Host "  1) Unplug ALL USB storage devices."
Write-Host "  2) Plug them back in one by one."
Write-Host "  3) Check This PC / Disk Management."
Write-Host "If a USB Mass Storage Device shows a down-arrow (disabled) in Device Manager -> right-click Enable."
exit 0
