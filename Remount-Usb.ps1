param(
  [Parameter(Mandatory=$true)]
  [ValidatePattern("^[A-Za-z]:?$")]
  [string]$Drive = "F:"
)

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = [Security.Principal.WindowsPrincipal]::new($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Hãy chạy PowerShell với quyền Administrator."
  }
}

function Normalize-Letter([string]$d) {
  $d.Trim().TrimEnd(':').ToUpper()
}

function Wait-Drive([string]$letter, [int]$timeoutSec = 8) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath ("{0}:\\" -f $letter)) { return $true }
    Start-Sleep -Milliseconds 300
  }
  return $false
}

function Rescan-Storage {
  try { Update-HostStorageCache | Out-Null } catch {}
  $dp = "rescan"
  $dp | diskpart | Out-Null
}

function Get-MountedDevices-VolumeGuidForLetter([string]$letter) {
  # Trả về dạng \\?\Volume{GUID}\ nếu tìm thấy mapping \DosDevices\F:
  $regPath = "HKLM:\SYSTEM\MountedDevices"
  $name = "\DosDevices\$letter`:"
  try {
    $raw = (Get-ItemProperty -Path $regPath -Name $name -ErrorAction Stop).$name
  } catch { return $null }

  # raw là byte[] kiểu REG_BINARY. Ta cố map ngược sang volume GUID bằng cách so sánh value.
  $props = Get-ItemProperty -Path $regPath
  foreach ($p in $props.PSObject.Properties) {
    if ($p.Name -like "\\??\\Volume{*}" -and $p.Value -is [byte[]]) {
      if ($p.Value.Length -eq $raw.Length) {
        $same = $true
        for ($i=0; $i -lt $raw.Length; $i++) {
          if ($raw[$i] -ne $p.Value[$i]) { $same = $false; break }
        }
        if ($same) {
          # Registry dùng \??\Volume{GUID}\ ; PowerShell volume path hay dùng \\?\Volume{GUID}\
          return ($p.Name -replace '^\\\?\?\\', '\\?\')  # \??\ -> \?\
        }
      }
    }
  }
  return $null
}

function Ensure-Letter-Free([string]$letter) {
  $vol = Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter -eq $letter
  if ($vol) {
    throw "Drive letter $letter`: đang bị ổ khác dùng (Volume: $($vol.FileSystemLabel)). Hãy đổi letter hoặc giải phóng trước."
  }
}

function Try-AssignLetter-ByVolumeGuid([string]$volumeGuidPath, [string]$letter) {
  if (-not $volumeGuidPath) { return $false }

  # volumeGuidPath dạng \\?\Volume{GUID}\  (hoặc \?\Volume{GUID}\ tuỳ replace)
  $guid = $volumeGuidPath
  if ($guid -notmatch 'Volume\{[0-9a-fA-F-]+\}\\?$') { }

  $vol = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.UniqueId -eq $guid }
  if (-not $vol) { return $false }

  # Lấy partition tương ứng để set letter
  $part = Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.AccessPaths -contains $guid }
  if (-not $part) { return $false }

  # Đưa disk online/readonly off nếu cần
  try {
    $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
    if ($disk.IsOffline)  { Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction SilentlyContinue | Out-Null }
    if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false -ErrorAction SilentlyContinue | Out-Null }
  } catch {}

  Ensure-Letter-Free $letter
  try {
    Set-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -NewDriveLetter $letter -ErrorAction Stop
    return $true
  } catch {
    return $false
  }
}

function Reset-Only-UsbDiskByDiskNumber([int]$diskNumber) {
  # Map DiskNumber -> Win32_DiskDrive.Index -> PNPDeviceID (chỉ đúng thiết bị đó)
  $dd = Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue |
    Where-Object { $_.Index -eq $diskNumber -and ($_.InterfaceType -eq "USB" -or $_.PNPDeviceID -like "USBSTOR*") } |
    Select-Object -First 1

  if (-not $dd) { return $false }

  $pnpId = $dd.PNPDeviceID
  if (-not $pnpId) { return $false }

  $dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -eq $pnpId } |
    Select-Object -First 1

  if (-not $dev) { return $false }

  try {
    Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop
    Start-Sleep -Seconds 2
    Enable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop
    return $true
  } catch {
    # "Generic failure" rất hay gặp nếu Windows không cho reset device đó theo cách này
    return $false
  }
}

# ================= MAIN =================
Assert-Admin
$L = Normalize-Letter $Drive

# 0) Nếu đã lên rồi thì OK luôn (và tránh “FAIL sai”)
if (Wait-Drive $L 1) {
  Write-Host "OK: $L`: đã đang mount."
  exit 0
}

# 1) Lấy Volume GUID mà trước đây letter này trỏ tới (nếu registry còn lưu)
$targetVolGuid = Get-MountedDevices-VolumeGuidForLetter $L
if ($targetVolGuid) {
  Write-Host "Target volume (from MountedDevices): $targetVolGuid"
} else {
  Write-Host "Không tìm thấy mapping trong MountedDevices cho $L`:. (Có thể Windows đã xoá mapping)"
}

# 2) Rescan + thử gán đúng volume GUID (nếu có)
Write-Host "==> Rescan..."
Rescan-Storage

if (Wait-Drive $L 4) {
  Write-Host "OK: $L`: đã mount sau rescan."
  exit 0
}

if (Try-AssignLetter-ByVolumeGuid $targetVolGuid $L) {
  if (Wait-Drive $L 6) {
    Write-Host "OK: Remount thành công -> $L`:\"
    exit 0
  }
}

# 3) Nếu chưa được: chỉ reset đúng USB disk tương ứng (nếu xác định được DiskNumber từ volume GUID)
$diskNumber = $null
if ($targetVolGuid) {
  $part = Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.AccessPaths -contains $targetVolGuid } | Select-Object -First 1
  if ($part) { $diskNumber = $part.DiskNumber }
}

if ($diskNumber -ne $null) {
  Write-Host "==> Reset only target USB disk (Disk #$diskNumber)..."
  [void](Reset-Only-UsbDiskByDiskNumber $diskNumber)
  Start-Sleep -Seconds 2

  Write-Host "==> Rescan..."
  Rescan-Storage

  if (Try-AssignLetter-ByVolumeGuid $targetVolGuid $L -or (Wait-Drive $L 6)) {
    if (Wait-Drive $L 6) {
      Write-Host "OK: Remount thành công -> $L`:\"
      exit 0
    }
  }
} else {
  Write-Host "Không xác định được DiskNumber của target -> không reset bừa các USB khác."
}

# 4) Final check (tránh FAIL sai do mount trễ)
if (Wait-Drive $L 8) {
  Write-Host "OK: $L`: đã mount (mount trễ)."
  exit 0
}

Write-Host "FAIL: Không remount được USB về $L`:."
Write-Host "Gợi ý: mapping ${L}: có thể không còn trong MountedDevices; hãy chạy lại khi USB vẫn cắm, hoặc dùng thêm tiêu chí (label/serial)."
exit 1