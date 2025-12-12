param(
  [Parameter(Mandatory=$true)]
  [ValidateSet("Capture","Remount")]
  [string]$Mode,

  [Parameter(Mandatory=$true)]
  [ValidatePattern("^[A-Za-z]:?$")]
  [string]$Drive,

  [string]$CachePath = "$PSScriptRoot\usb_remount_cache.json",

  # thời gian chờ mount lại
  [int]$WaitSec = 12
)

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = [Security.Principal.WindowsPrincipal]::new($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Hãy chạy PowerShell với quyền Administrator."
  }
}

function Normalize-Letter([string]$d) { $d.Trim().TrimEnd(':').ToUpper() }

function Wait-Drive([string]$letter, [int]$timeoutSec) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath ("{0}:\\" -f $letter)) { return $true }
    Start-Sleep -Milliseconds 250
  }
  return $false
}

function Rescan-Storage {
  try { Update-HostStorageCache | Out-Null } catch {}
  "rescan" | diskpart | Out-Null
}

function Ensure-Letter-Free([string]$letter) {
  $vol = Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter -eq $letter
  if ($vol) {
    throw "Drive letter $letter`: đang bị ổ khác dùng (Label: $($vol.FileSystemLabel)). Hãy giải phóng/đổi letter trước."
  }
}

function Get-DiskDriveCimByIndex([int]$idx) {
  Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue |
    Where-Object { $_.Index -eq $idx } |
    Select-Object -First 1
}

function Capture-UsbState([string]$letter, [string]$path) {
  if (-not (Test-Path ("$letter`:\"))) { throw "Không thấy $letter`:\. Hãy capture khi ổ đang mount." }

  $vol = Get-Volume -DriveLetter $letter -ErrorAction Stop
  $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
  $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop

  # Win32_DiskDrive.Index thường trùng Disk.Number cho USB storage như output bạn gửi
  $dd = Get-DiskDriveCimByIndex $disk.Number
  $serial = $null
  $pnpId  = $null
  $iface  = $null
  if ($dd) {
    $serial = ($dd.SerialNumber | ForEach-Object { $_.Trim() })
    $pnpId  = $dd.PNPDeviceID
    $iface  = $dd.InterfaceType
  }

  $entry = [ordered]@{
    DriveLetter      = $letter
    CapturedAt       = (Get-Date).ToString("s")
    VolumeUniqueId   = $vol.UniqueId            # \\?\Volume{GUID}\
    FileSystem       = $vol.FileSystem
    Label            = $vol.FileSystemLabel
    VolumeSize       = [int64]$vol.Size
    DiskNumber       = [int]$disk.Number
    DiskFriendlyName = $disk.FriendlyName
    DiskBusType      = $disk.BusType.ToString()
    DiskSize         = [int64]$disk.Size
    PnpDeviceId      = $pnpId                   # để reset đúng device (không đụng ổ khác)
    DiskSerial       = $serial                  # nếu có
    InterfaceType    = $iface
  }

  $cache = @{}
  if (Test-Path $path) {
    try { $cache = (Get-Content $path -Raw | ConvertFrom-Json -AsHashtable) } catch { $cache = @{} }
  }
  $cache[$letter] = $entry
  ($cache | ConvertTo-Json -Depth 6) | Set-Content -Path $path -Encoding UTF8

  Write-Host "OK: Đã capture $letter`: -> $path"
  Write-Host ("    Disk# {0}, Size {1:N1}GB, BusType {2}, Serial '{3}'" -f $entry.DiskNumber, ($entry.DiskSize/1GB), $entry.DiskBusType, ($entry.DiskSerial ?? ""))
}

function Try-Reset-OnlyDevice([string]$pnpId) {
  if (-not $pnpId) { return $false }
  $dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -eq $pnpId } | Select-Object -First 1
  if (-not $dev) { return $false }

  try {
    Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop
    Start-Sleep -Seconds 2
    Enable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop
    return $true
  } catch {
    return $false
  }
}

function Find-DiskMatch($entry) {
  # Ưu tiên: Serial -> PNPDeviceID -> (FriendlyName + Size)
  $allDd = Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue

  if ($entry.DiskSerial) {
    $m = $allDd | Where-Object { ($_.SerialNumber -as [string]).Trim() -like "*$($entry.DiskSerial)*" } | Select-Object -First 1
    if ($m) { return [int]$m.Index }
  }

  if ($entry.PnpDeviceId) {
    $m = $allDd | Where-Object { $_.PNPDeviceID -eq $entry.PnpDeviceId } | Select-Object -First 1
    if ($m) { return [int]$m.Index }
  }

  if ($entry.DiskSize -and $entry.DiskFriendlyName) {
    $m = $allDd | Where-Object {
      $_.Model -eq $entry.DiskFriendlyName -and
      $_.Size -and ([int64]$_.Size -ge ($entry.DiskSize*0.98)) -and ([int64]$_.Size -le ($entry.DiskSize*1.02))
    } | Select-Object -First 1
    if ($m) { return [int]$m.Index }
  }

  return $null
}

function Remount-FromCache([string]$letter, [string]$path, [int]$waitSec) {
  if (Wait-Drive $letter 1) { Write-Host "OK: $letter`: đã đang mount."; return }

  if (-not (Test-Path $path)) { throw "Không thấy cache file: $path. Hãy chạy -Mode Capture trước." }
  $cache = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
  if (-not $cache.ContainsKey($letter)) { throw "Cache không có entry cho $letter`:. Hãy Capture ổ đó khi đang mount." }
  $entry = $cache[$letter]

  Ensure-Letter-Free $letter

  Write-Host "Loaded cache for $letter`: (CapturedAt $($entry.CapturedAt))"
  Write-Host ("  DiskFriendlyName: {0}; DiskSize: {1:N1}GB; Serial: '{2}'" -f $entry.DiskFriendlyName, ($entry.DiskSize/1GB), ($entry.DiskSerial ?? ""))

  # 1) Rescan + chờ Windows tự mount lại
  Rescan-Storage
  if (Wait-Drive $letter 4) { Write-Host "OK: $letter`: đã mount sau rescan."; return }

  # 2) Tìm đúng disk theo cache
  $diskIndex = Find-DiskMatch $entry
  if ($diskIndex -eq $null) {
    Write-Host "FAIL: Không tìm thấy disk match từ cache (serial/pnp/model+size)."
    Write-Host "Gợi ý: Capture lại khi ổ đang mount để có Serial/PNPDeviceID tốt hơn."
    return
  }

  # 3) Thử assign letter cho partition phù hợp trên disk đó
  $disk = Get-Disk -Number $diskIndex -ErrorAction SilentlyContinue
  if ($disk) {
    if ($disk.IsOffline)  { Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction SilentlyContinue | Out-Null }
    if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false -ErrorAction SilentlyContinue | Out-Null }
  }

  # Chọn partition “hợp lý”: có Volume/Filesystem (nếu đọc được)
  $parts = Get-Partition -DiskNumber $diskIndex -ErrorAction SilentlyContinue |
    Where-Object { -not $_.DriveLetter -and $_.Size -gt 0 } |
    Sort-Object Size -Descending

  foreach ($p in $parts) {
    try {
      Set-Partition -DiskNumber $diskIndex -PartitionNumber $p.PartitionNumber -NewDriveLetter $letter -ErrorAction Stop
      if (Wait-Drive $letter $waitSec) { Write-Host "OK: Remount thành công -> $letter`:\ (Disk#$diskIndex Part#$($p.PartitionNumber))"; return }
    } catch {}
  }

  # 4) Nếu vẫn chưa: reset đúng device theo PNPDeviceID trong cache (KHÔNG đụng ổ khác)
  Write-Host "==> Try reset ONLY target device (from cache PNPDeviceID)..."
  [void](Try-Reset-OnlyDevice $entry.PnpDeviceId)
  Start-Sleep -Seconds 2
  Rescan-Storage

  # Thử lại assign
  $parts = Get-Partition -DiskNumber $diskIndex -ErrorAction SilentlyContinue |
    Where-Object { -not $_.DriveLetter -and $_.Size -gt 0 } |
    Sort-Object Size -Descending

  foreach ($p in $parts) {
    try {
      Set-Partition -DiskNumber $diskIndex -PartitionNumber $p.PartitionNumber -NewDriveLetter $letter -ErrorAction Stop
      if (Wait-Drive $letter $waitSec) { Write-Host "OK: Remount thành công sau reset -> $letter`:\ (Disk#$diskIndex Part#$($p.PartitionNumber))"; return }
    } catch {}
  }

  # Final wait tránh false FAIL do mount trễ
  if (Wait-Drive $letter $waitSec) { Write-Host "OK: $letter`: đã mount (mount trễ)."; return }

  Write-Host "FAIL: Không remount được $letter`: dựa trên cache."
}

# ===== MAIN =====
Assert-Admin
$L = Normalize-Letter $Drive

switch ($Mode) {
  "Capture" { Capture-UsbState $L $CachePath }
  "Remount" { Remount-FromCache $L $CachePath $WaitSec }
}
