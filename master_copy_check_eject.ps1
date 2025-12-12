param(
    # Thư mục nguồn cần copy (chứa dữ liệu gốc)
    [string]$SourceRoot = "D:\A Di Da Phat",

    # Danh sách ổ đích (USB) cần xử lý
    [string[]]$DestDrives = @("F:", "G:", "H:", "I:", "J:", "K:", "L:", "M:"),

    # Đường dẫn script CHECK
    [string]$CheckScriptPath = ".\check_copy_hash.ps1",

    # Tham số cho bước CHECK
    [switch]$EnableHash,       # bật check hash
    [int]$HashLastN = 100,     # số file cuối cùng để hash (0 = hash toàn bộ)
    [ValidateSet('MD5', 'SHA256')]
    [string]$HashAlgorithm = 'MD5',

    # Đường dẫn script EJECT
    [string]$EjectScriptPath = ".\removedrv.ps1",

    # Đường dẫn script remount USB (dùng để capture / remount)
    [string]$RemountScriptPath = ".\Remount-Usb.ps1",
    [string]$RemountCachePath  = ".\usb_remount_cache.json",

    # Thư mục log
    [string]$LogDir = ".\logs",

    # Không hỏi confirm (auto yes)
    [switch]$AutoYes
)
# Goc thuc thi (de xu ly duong dan tuong doi khi chay tu cwd khac)
$ScriptDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).ProviderPath }

# Chuan hoa duong dan tuong doi thanh tuyet doi (dua tren thu muc script)
if (-not [System.IO.Path]::IsPathRooted($CheckScriptPath)) {
    $CheckScriptPath = Join-Path $ScriptDir $CheckScriptPath
}
if (-not [System.IO.Path]::IsPathRooted($EjectScriptPath)) {
    $EjectScriptPath = Join-Path $ScriptDir $EjectScriptPath
}
if (-not [System.IO.Path]::IsPathRooted($RemountScriptPath)) {
    $RemountScriptPath = Join-Path $ScriptDir $RemountScriptPath
}
if (-not [System.IO.Path]::IsPathRooted($RemountCachePath)) {
    $RemountCachePath = Join-Path $ScriptDir $RemountCachePath
}
if (-not [System.IO.Path]::IsPathRooted($LogDir)) {
    $LogDir = Join-Path $ScriptDir $LogDir
}

# Kiểm tra quyền admin (phục vụ cảnh báo remount)
$script:IsAdmin = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($id)
    $script:IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
catch { $script:IsAdmin = $false }


# ================== HÀM GHI LOG ==================
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[{0}] [{1}] {2}" -f $timestamp, $Level.ToUpper(), $Message

    switch ($Level.ToUpper()) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN" { Write-Host $line -ForegroundColor Yellow }
        "INFO" { Write-Host $line -ForegroundColor Gray }
        default { Write-Host $line }
    }

    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line -Encoding utf8
    }
}

function Wait-DriveReady {
    param(
        [string]$Drive,     # ví dụ 'F:' hoặc 'F'
        [int]$TimeoutSec = 30
    )

    $root = ($Drive.TrimEnd(':') + ":\")
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try {
            if (Test-Path $root) {
                return $true
            }
        }
        catch {
            # ignore, thử lại
        }
        Start-Sleep -Milliseconds 500
    }

    return $false
}

# Bao dam duong dan khi dua vao cmdline khong lam thoat dau nhay do backslash cuoi
function Quote-PathArg {
    param([string]$Path)

    $normalized = $Path.Trim('"')
    if ($normalized.EndsWith('\')) {
        # Nhan doi backslash cuoi de khong nuot dau nhay ket thuc
        $normalized += '\'
    }

    return '"{0}"' -f $normalized
}

# Thử remount USB dựa trên cache (Remount-Usb.ps1)
function Try-RemountDrive {
    param(
        [string]$DriveLetter,
        [int]$WaitSec = 20
    )

    if (-not (Test-Path $RemountScriptPath)) {
        return $false
    }

    Write-Log ("Thử remount ổ {0}..." -f $DriveLetter) "WARN"
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemountScriptPath -Mode Remount -Drive $DriveLetter -CachePath $RemountCachePath -WaitSec $WaitSec
        $code = $LASTEXITCODE
    }
    catch {
        Write-Log ("Lỗi khi chạy Remount-Usb cho ổ {0}: {1}" -f $DriveLetter, $_) "ERROR"
        return $false
    }

    if ($code -eq 0 -and (Wait-DriveReady $DriveLetter $WaitSec)) {
        Write-Log ("Remount ổ {0} thành công." -f $DriveLetter)
        return $true
    }

    Write-Log ("Remount ổ {0} thất bại (ExitCode={1})." -f $DriveLetter, $code) "WARN"
    return $false
}
# ================== KHỞI TẠO LOG ==================
if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}
$logName = "copycheckeject_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss")
$script:LogFile = Join-Path $LogDir $logName
$script:LogFile = [System.IO.Path]::GetFullPath($script:LogFile)

Write-Log "===== BẮT ĐẦU QUY TRÌNH COPY - CHECK - EJECT ====="

# ================== KIỂM TRA THAM SỐ CƠ BẢN ==================

if (-not (Test-Path $SourceRoot)) {
    Write-Log "Thư mục nguồn không tồn tại: $SourceRoot" "ERROR"
    Write-Host ""
    Write-Host "Vui lòng kiểm tra lại tham số -SourceRoot." -ForegroundColor Red
    exit 1
}
# Chuẩn hoá SourceRoot: bỏ nháy thừa, chuyển thành full path
$SourceRoot = $SourceRoot.Trim('"')
$SourceRoot = (Resolve-Path $SourceRoot).ProviderPath

if (-not $DestDrives -or $DestDrives.Count -eq 0) {
    Write-Log "Không có ổ đích nào được chỉ định." "ERROR"
    exit 1
}

# Chuẩn hóa format ổ kiểu 'F:'
$DestDrives = $DestDrives | ForEach-Object {
    ($_ -replace '\\', '').TrimEnd(':') + ':'
} | Select-Object -Unique

# ================== HIỂN THỊ CẤU HÌNH & XÁC NHẬN ==================
Write-Host "===== CẤU HÌNH HIỆN TẠI =====" -ForegroundColor Cyan
Write-Host "SourceRoot      : $SourceRoot"
Write-Host "DestDrives      : $($DestDrives -join ', ')"
Write-Host "CheckScriptPath : $CheckScriptPath"
Write-Host "EjectScriptPath : $EjectScriptPath"
Write-Host "RemountScript   : $RemountScriptPath"
Write-Host "RemountCache    : $RemountCachePath"
Write-Host "LogFile         : $LogFile"
Write-Host "EnableHash      : $($EnableHash.IsPresent)"
Write-Host "HashLastN       : $HashLastN"
Write-Host "HashAlgorithm   : $HashAlgorithm"
Write-Host ""
if ((Test-Path $RemountScriptPath) -and (-not $script:IsAdmin)) {
    Write-Host "LƯU Ý: Để remount USB khi bị rút/mất kết nối, hãy chạy PowerShell 'Run as Administrator'." -ForegroundColor Yellow
    Write-Log  "Lưu ý: cần quyền Administrator để remount USB khi bị rút/mất kết nối." "WARN"
}



if (-not $AutoYes) {
    $confirm = Read-Host "Tiếp tục với cấu hình trên? (Y/N, mặc định = Y)"
    if ($confirm -and $confirm.ToUpper() -ne "Y") {
        Write-Log "Người dùng hủy tiến trình." "WARN"
        exit 0
    }
}

# ================== HÀM TÍNH KÍCH THƯỚC SOURCE (THEO ROBOCOPY /L) ==================
function Get-SourceSize {
    param([string]$Path)

    Write-Log "Đang ước lượng dung lượng source bằng robocopy /L (bao gồm cả symlink/junction)..."
    
    # Đảm bảo Path đã là full path, không có nháy
    $Path = $Path.Trim('"')
    $Path = (Resolve-Path $Path).ProviderPath

    # Tạo thư mục tạm làm đích giả cho robocopy /L
    $tempDest = Join-Path $env:TEMP ("_rcsz_" + [guid]::NewGuid().ToString())
    New-Item -Path $tempDest -ItemType Directory -Force | Out-Null

    # /L: chỉ liệt kê, không copy /E: copy toàn bộ cây /BYTES: tính theo byte
    # /R:0 /W:0: không retry /NFL /NDL: không log file/dir chi tiết
    $params = @(
        $Path,
        $tempDest,
        "/E",       # full tree
        "/L",       # chỉ liệt kê, không copy
        "/BYTES",
        "/R:0",
        "/W:0",
        "/NFL",
        "/NDL",
        "/NP"
    )

    $output = & robocopy @params 
    Remove-Item -Path $tempDest -Recurse -Force -ErrorAction SilentlyContinue

    $bytes = 0L
    foreach ($line in $output) {
        # Tìm dòng "Bytes : 12,345,678"
        if ($line -match "Bytes\s*:\s*([\d,]+)") {
            $bytes = [int64]($matches[1] -replace ",", "")
        }
    }

    if ($bytes -le 0) {
        Write-Log "Không parse được dung lượng từ robocopy, fallback sang Get-ChildItem (follow symlink nếu có)." "WARN"

        $gciParams = @{
            Path    = $Path
            Recurse = $true
            File    = $true
            Force   = $true
        }

        $gciCmd = Get-Command Get-ChildItem
        if ($gciCmd.Parameters.ContainsKey('FollowSymlink')) {
            $gciParams['FollowSymlink'] = $true
        }

        $files = Get-ChildItem @gciParams
        $bytes = ($files | Measure-Object Length -Sum).Sum
    }

    Write-Log ("Tổng dung lượng source: {0:N0} bytes (~{1:N2} GB)" -f $bytes, ($bytes / 1GB))
    return $bytes
}

$sourceSize = Get-SourceSize -Path $SourceRoot

# ================== LỌC CHỈ Ổ USB (REMOVABLE) ==================
Write-Log "Đang dò danh sách ổ USB (removable)..."

$usbDisks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=2" |
Select-Object DeviceID, Size, FreeSpace

$usbMap = @{}
foreach ($d in $usbDisks) {
    $usbMap[$d.DeviceID.ToUpper()] = $d
}

$ValidTargets = @()

foreach ($drv in $DestDrives) {
    $upper = $drv.ToUpper()
    if ($usbMap.ContainsKey($upper)) {
        $disk = $usbMap[$upper]
        Write-Log ("Ổ {0} (USB) Size={1:N2}GB, Free={2:N2}GB" -f `
                $upper, ($disk.Size / 1GB), ($disk.FreeSpace / 1GB))
        $ValidTargets += $upper
    }
    else {
        Write-Log "Ổ $upper KHÔNG phải USB (hoặc không tìm thấy). Bỏ qua." "WARN"
    }
}

if ($ValidTargets.Count -eq 0) {
    Write-Log "Không có ổ USB hợp lệ để xử lý." "ERROR"
    exit 1
}

# ================== CAPTURE THÔNG TIN REMOUNT ==================
if (Test-Path $RemountScriptPath) {
    Write-Log "Capture thông tin remount cho các ổ USB hợp lệ..."
    foreach ($drv in $ValidTargets) {
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemountScriptPath -Mode Capture -Drive $drv -CachePath $RemountCachePath
            $capCode = $LASTEXITCODE
            if ($capCode -eq 0) {
                Write-Log ("Capture remount OK cho ổ {0}, cache: {1}" -f $drv, $RemountCachePath)
            } else {
                Write-Log ("Capture remount cho ổ {0} thất bại (ExitCode={1}). Tiếp tục mà không có cache remount cho ổ này." -f $drv, $capCode) "WARN"
            }
        }
        catch {
            Write-Log ("Lỗi khi capture remount ổ {0}: {1}" -f $drv, $_) "WARN"
        }
    }
} else {
    Write-Log "Không tìm thấy Remount-Usb.ps1, bỏ qua bước capture remount." "WARN"
}

# ================== CẢNH BÁO RIÊNG CHO Ổ USB >= 16GB ==================
$LargeUsb = $ValidTargets | Where-Object {
    $usbMap[$_].Size -ge (16GB)
}

if ($LargeUsb.Count -gt 0 -and -not $AutoYes) {
    Write-Host ""
    Write-Host "CẢNH BÁO: các ổ USB sau có dung lượng >= 16GB, có thể bị XOÁ/FORMAT:" -ForegroundColor Yellow
    $LargeUsb | ForEach-Object {
        $disk = $usbMap[$_]
        Write-Host ("  {0}  ~{1:N2} GB" -f $_, ($disk.Size / 1GB)) -ForegroundColor Yellow
    }
    $ans = Read-Host "TIẾP TỤC xử lý các ổ lớn này? (Y = tiếp tục, giá trị khác = BỎ QUA các ổ >=16GB)"
    if (-not ($ans -and $ans.ToUpper() -eq 'Y')) {
        Write-Log "Người dùng chọn BỎ QUA các ổ >=16GB." "WARN"
        # Loại các ổ lớn khỏi danh sách
        $ValidTargets = $ValidTargets | Where-Object { $LargeUsb -notcontains $_ }
    }
}

if ($ValidTargets.Count -eq 0) {
    Write-Log "Sau khi bỏ qua ổ lớn, không còn ổ USB nào để xử lý." "ERROR"
    exit 1
}

# ================== ĐÁNH GIÁ TỪNG Ổ: CAPACITY + DỮ LIỆU HIỆN CÓ ==================
# Rule:
# 1) Nếu dung lượng ổ (Size) < dung lượng source → bỏ qua, không làm gì.
# 2) Nếu Size >= sourceSize:
#    - Tính usedMB, usedPct.
#    - Nếu usedMB < 20MB → giữ nguyên data, chỉ copy thêm.
#    - Nếu usedMB >= 20MB:
#       * Nếu usedPct < 20% → OPTION A: xóa toàn bộ file trên ổ.
#       * Ngược lại → OPTION B: QUICK FORMAT.
# 3) Sau khi xử lý data, check lại freeSpace >= sourceSize → mới được copy.

$PreparedTargets = @()
$MirrorTargets   = @()

foreach ($drv in $ValidTargets) {

    $disk = $usbMap[$drv]
    $totalSize = [double]$disk.Size
    $freeSpace = [double]$disk.FreeSpace
    $usedBytes = $totalSize - $freeSpace
    $usedMB = $usedBytes / 1MB
    $usedPct = if ($totalSize -gt 0) { $usedBytes / $totalSize } else { 0 }

    Write-Log ("--- ĐÁNH GIÁ Ổ {0} ---" -f $drv)
    Write-Log ("Size={0:N2}GB, Free={1:N2}GB, Used={2:N2}MB ({3:P1})" -f `
        ($totalSize / 1GB), ($freeSpace / 1GB), $usedMB, $usedPct)

    # *** BƯỚC 0: check capacity tổng có đủ chứa source không ***
    if ($totalSize -gt $sourceSize) {

        # BƯỚC 1: quyết định xử lý dữ liệu hiện có
        $skipCleanup = $false
        if (-not $AutoYes -and $freeSpace -ge $sourceSize -and $usedMB -ge 20) {
            Write-Host ""
            Write-Host ("Ổ {0} đang còn trống {1:N2}GB, đủ để chứa source ~{2:N2}GB." -f $drv, ($freeSpace / 1GB), ($sourceSize / 1GB)) -ForegroundColor Yellow
            $ansKeep = Read-Host "GIỮ NGUYÊN dữ liệu, KHÔNG xóa/format? (Y = giữ, giá trị khác = vẫn xóa/format)"
            if ($ansKeep -and $ansKeep.ToUpper() -eq "Y") {
                $skipCleanup = $true
                Write-Log ("Người dùng chọn giữ nguyên dữ liệu trên ổ {0} (không xóa/format vì freeSpace đủ)." -f $drv) "WARN"
            }
        }

        if ($usedMB -lt 20) {
            Write-Log "Dữ liệu hiện tại trên ổ $drv < 20MB → giữ nguyên, chỉ copy thêm."
            # Không đụng vào dữ liệu; freeSpace vẫn giữ giá trị hiện tại
        }
        else {
            Write-Log ("CẢNH BÁO: ổ {0} đang có dữ liệu {1:N2}MB." -f $drv, $usedMB) "WARN"

            if ($skipCleanup) {
                Write-Log ("Bỏ qua xóa/format ổ {0} theo lựa chọn của người dùng." -f $drv) "WARN"
            }
            elseif ($usedPct -lt 0.2) {
                # OPTION A: xóa file
                Write-Log ("Áp dụng OPTION A cho {0}: Xóa toàn bộ file (Used<{1:P0} dung lượng)." -f $drv, 0.2)
                try {
                    Get-ChildItem -Path ($drv + "\") -Force | Remove-Item -Recurse -Force -ErrorAction Stop
                    Write-Log "Đã xóa toàn bộ dữ liệu trên ổ $drv."
                    # tùy chọn: chờ ổ ổn định lại
                    if (-not (Wait-DriveReady $drv 15)) {
                        Write-Log "Sau khi xóa dữ liệu, ổ $drv có vẻ không ổn định. BỎ QUA ổ này." "ERROR"
                        continue
                    }
                    # Reload thông tin disk
                    $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drv)
                    $totalSize = [double]$disk.Size
                    $freeSpace = [double]$disk.FreeSpace
                }
                catch {
                    Write-Log "Lỗi khi xóa dữ liệu trên ổ ${drv}: $_" "ERROR"
                    continue
                }
            }
            else {
                # OPTION B: quick format FAT32
                # Nếu không AutoYes: kiểm tra nhanh ổ đích đã khớp source chưa (không hash)
                if (-not $AutoYes -and (Test-Path $CheckScriptPath)) {
                    Write-Log ("Kiểm tra nhanh ổ {0} trước khi format..." -f $drv)
                    $quickArgs = @(
                        "-NoProfile", "-ExecutionPolicy", "Bypass",
                        "-File", $CheckScriptPath,
                        "-SourceRoot", $SourceRoot,
                        "-DestDrives", $drv,
                        "-NoConfirm",
                        "-NoPause",
                        "-HashLastN", "0"
                    )
                    if ($LogFile) { $quickArgs += @("-LogFile", $LogFile) }
                    & powershell.exe @quickArgs
                    $quickCode = $LASTEXITCODE
                    $mirrorCopy = $false
                    switch ($quickCode) {
                        0 {
                            Write-Log ("Ổ {0} hiện đã khớp với source (check nhanh, không hash). Bỏ qua format, tiếp tục copy bình thường." -f $drv) "WARN"
                            $skipCleanup = $true
                        }
                        2 {
                            Write-Log ("Check nhanh ổ {0} phát hiện sai khác size/hash (ExitCode=2). Bỏ qua format, tiếp tục copy bình thường." -f $drv) "WARN"
                            $skipCleanup = $true
                        }
                        4 {
                            Write-Log ("Check nhanh ổ {0} phát hiện thiếu file (ExitCode=4). Bỏ qua format, tiếp tục copy bình thường." -f $drv) "WARN"
                            $skipCleanup = $true
                        }
                        3 {
                            Write-Log ("Check nhanh ổ {0} phát hiện DEST thừa file (ExitCode=3). Bỏ qua format, copy kiểu MIRROR để xóa file dư." -f $drv) "WARN"
                            $skipCleanup = $true
                            $mirrorCopy = $true
                        }
                        Default {
                            Write-Log ("Check nhanh trước format ổ {0} báo ExitCode={1}, tiếp tục format." -f $drv, $quickCode) "WARN"
                        }
                    }
                    if ($mirrorCopy -and ($MirrorTargets -notcontains $drv)) {
                        $MirrorTargets += $drv
                    }
                }

                if ($skipCleanup) {
                    if ($freeSpace -lt $sourceSize) { $freeSpace = [double]$totalSize }
                }
                else {
                    # Windows thường không cho FAT32 > 32GB
                    if ($totalSize -gt 32GB) {
                        Write-Log ("Ổ {0} > 32GB, thường không format FAT32 được trên Windows. BỎ QUA ổ này." -f $drv) "ERROR"
                        continue
                    }

                    try {
                        $letter = $drv.TrimEnd(':')
                        Write-Log ("Đang format FAT32 ổ {0}..." -f $drv) "WARN"
                        Format-Volume -DriveLetter $letter -FileSystem FAT32 -NewFileSystemLabel "USB_$letter" -Confirm:$false -Force -ErrorAction Stop
                        Write-Log "Đã quick format FAT32 ổ $drv."

                        # Cho ổ mount lại
                        if (-not (Wait-DriveReady $drv 30)) {
                            Write-Log "Sau khi format, ổ $drv không ready trong 30s. BỎ QUA ổ này." "ERROR"
                            continue
                        }

                        $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drv)
                        $totalSize = [double]$disk.Size
                        $freeSpace = [double]$disk.FreeSpace
                    }
                    catch {
                        Write-Log "Lỗi khi format ổ ${drv}: $_" "ERROR"
                        continue
                    }
                }
            }
        }

        # BƯỚC 2: check freeSpace sau xử lý
        if ($freeSpace -lt $sourceSize) {
            Write-Log ("Ổ {0} KHÔNG đủ dung lượng trống sau xử lý. Free={1:N2}GB, Source~{2:N2}GB" -f `
                    $drv, ($freeSpace / 1GB), ($sourceSize / 1GB)) "ERROR"
            continue
        }

        Write-Log ("Ổ {0} đủ điều kiện để copy." -f $drv)
        $PreparedTargets += $drv
    }
}
if ($PreparedTargets.Count -eq 0) {
    Write-Log "Không còn ổ nào đủ điều kiện để copy sau khi đánh giá dung lượng & dữ liệu." "ERROR"
    exit 1
}

# ================== BƯỚC 2: COPY (song song, có phục hồi rút-gắn) ==================
function Start-CopyProcess {
    param(
        [string]$DriveLetter,
        [bool]$UseMirror,
        [int]$ThreadNo
    )

    if (-not (Wait-DriveReady $DriveLetter 30)) {
        Write-Log ("Ổ {0} KHÔNG ready trước khi copy." -f $DriveLetter) "ERROR"
        if (Try-RemountDrive -DriveLetter $DriveLetter -WaitSec 30) {
            Write-Log ("Ổ {0} đã remount, tiếp tục copy." -f $DriveLetter) "WARN"
        } else {
            return $null
        }
    }

    $destPath = Join-Path $DriveLetter (Split-Path $SourceRoot -Leaf)
    try {
        if (-not (Test-Path $destPath)) {
            New-Item -Path $destPath -ItemType Directory -Force | Out-Null
        }
    }
    catch {
        Write-Log "Lỗi khi tạo thư mục đích $destPath trên ổ ${DriveLetter}: $_" "ERROR"
        return $null
    }

    $srcArg = Quote-PathArg $SourceRoot
    $dstArg = Quote-PathArg $destPath
    $modeSwitch = if ($UseMirror) { "/MIR" } else { "/E" }

    $params = @(
        $srcArg,
        $dstArg,
        $modeSwitch,
        "/R:2",
        "/W:2",
        "/LOG+:$LogFile",
        "/NFL",
        "/NDL",
        "/NP",
        "/Z",
        "/MT:$ThreadNo"
    )
    #giải thích tham số:
    # /E: copy toàn bộ cây thư mục, bao gồm thư mục rỗng
    # /R:2: retry 2 lần nếu lỗi
    # /W:2: chờ 2 giây giữa các lần retry
    # /LOG+: append log vào file log chung
    # /NFL: không log tên file
    # /NDL: không log tên thư mục
    # /NP: không log phần trăm hoàn thành
    # /Z: copy ở chế độ restartable
    # /MT:16: copy đa luồng (16 luồng)

    if ($UseMirror) {
        Write-Log ("Copy ổ {0} chạy MIRROR (do quick check ExitCode=3)." -f $DriveLetter) "WARN"
    }

    Write-Log ("Chạy robocopy tới {0}: robocopy {1}" -f $DriveLetter, ($params -join ' '))
    $p = Start-Process -FilePath "robocopy.exe" -ArgumentList ($params -join ' ') -PassThru -WindowStyle Hidden
    return [PSCustomObject]@{
        Drive     = $DriveLetter
        Process   = $p
        UseMirror = $UseMirror
    }
}

Write-Log "BẮT ĐẦU BƯỚC COPY (robocopy)..."

$copyResults = @{}
$active = @()
$threadNo = [int][Math]::Floor(16 / $PreparedTargets.Count)
if ($threadNo -lt 1) { $threadNo = 1 }
if ($threadNo -gt 8) { $threadNo = 8 }

# Khởi động copy cho tất cả ổ (song song)
foreach ($drv in $PreparedTargets) {
    $useMirror = $MirrorTargets -contains $drv
    $procObj = Start-CopyProcess -DriveLetter $drv -UseMirror $useMirror -ThreadNo $threadNo
    if ($procObj) {
        $active += $procObj
    } else {
        $copyResults[$drv] = 999
    }
    Start-Sleep -Milliseconds 300
}

# Giám sát tiến trình copy theo ổ
while ($active.Count -gt 0) {
    $procs = $active | Select-Object -ExpandProperty Process
    $finished = Wait-Process -InputObject $procs -Any
    $done = $active | Where-Object { $_.Process.Id -eq $finished.Id }
    if (-not $done) { continue }

    $drv = $done.Drive
    $code = $done.Process.ExitCode
    $copyResults[$drv] = $code
    $active = $active | Where-Object { $_.Process.Id -ne $finished.Id }

    if ($code -lt 8) {
        Write-Log ("COPY tới {0} HOÀN TẤT. ExitCode={1}" -f $drv, $code)
        continue
    }

    Write-Log ("COPY tới {0} THẤT BẠI. ExitCode={1}" -f $drv, $code) "ERROR"
    if ($AutoYes) {
        Write-Log "AutoYes đang bật -> không thử lại copy cho ổ này." "ERROR"
        continue
    }

    $stillThere = Test-Path ($drv + "\")
    if (-not $stillThere) {
        Write-Log ("Ổ {0} không còn sẵn sàng (có thể bị rút). Thử remount..." -f $drv) "ERROR"
        $remounted = Try-RemountDrive -DriveLetter $drv -WaitSec 30
        if ($remounted) {
            Write-Log ("Remount ổ {0} thành công, thử copy lại..." -f $drv) "WARN"
            $retryProc = Start-CopyProcess -DriveLetter $drv -UseMirror ($MirrorTargets -contains $drv) -ThreadNo $threadNo
            if ($retryProc) {
                $copyResults.Remove($drv) | Out-Null
                $active += $retryProc
                continue
            } else {
                Write-Log ("Khởi động copy lại ổ {0} sau remount thất bại." -f $drv) "ERROR"
            }
        }
    }

    $ans = Read-Host ("Ổ {0} gặp lỗi (ExitCode={1}). Cắm lại/Remount nếu đã rút, nhập Y để thử copy lại, phím khác = bỏ qua ổ này" -f $drv, $code)
    if ($ans -and $ans.ToUpper() -eq 'Y') {
        if (-not (Wait-DriveReady $drv 60)) {
            Write-Log ("Ổ {0} vẫn không sẵn sàng sau 60s. Bỏ qua ổ này." -f $drv) "ERROR"
            continue
        }
        Write-Log ("Thử copy lại ổ {0}..." -f $drv)
        $retryProc = Start-CopyProcess -DriveLetter $drv -UseMirror ($MirrorTargets -contains $drv) -ThreadNo $threadNo
        if ($retryProc) {
            $copyResults.Remove($drv) | Out-Null
            $active += $retryProc
        } else {
            Write-Log ("Khởi động copy lại ổ {0} thất bại, giữ nguyên lỗi trước đó." -f $drv) "ERROR"
        }
    }
    else {
        Write-Log ("Người dùng chọn bỏ qua copy cho ổ {0}." -f $drv) "WARN"
    }
}

if ($copyResults.Values | Where-Object { $_ -ge 8 }) {
    Write-Log "Một hoặc nhiều ổ copy lỗi. DỪNG quy trình, KHÔNG thực hiện CHECK và EJECT." "ERROR"
    exit 1
}

Write-Log "Tất cả copy robocopy hoàn tất (không lỗi mức >=8)."
# ================== BƯỚC 3: CHECK ==================
if (-not (Test-Path $CheckScriptPath)) {
    Write-Log "Không tìm thấy script CHECK: $CheckScriptPath. Bỏ qua bước CHECK." "WARN"
}
else {
    Write-Log "BẮT ĐẦU BƯỚC CHECK bằng script: $CheckScriptPath"

    $checkScriptFull = [System.IO.Path]::GetFullPath($CheckScriptPath)
    $checkArgs = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $checkScriptFull,
        "-SourceRoot", $SourceRoot,
        "-DestDrives"
    ) + $PreparedTargets + @(
        "-NoConfirm",
        "-NoPause",
        "-LogFile", $LogFile
    )

    if ($EnableHash) {
        $checkArgs += @(
            "-Hash",
            "-HashLastN", $HashLastN,
            "-HashAlgorithm", $HashAlgorithm
        )
    }

    & powershell.exe @checkArgs
    $checkCode = $LASTEXITCODE

    if ($checkCode -ne 0) {
        Write-Log ("BƯỚC CHECK báo lỗi (ExitCode={0}). DỪNG, KHÔNG EJECT." -f $checkCode) "ERROR"
        exit 1
    }
    else {
        Write-Log "BƯỚC CHECK hoàn tất, không có lỗi nghiêm trọng."
    }
}

# ================== BƯỚC 4: EJECT ==================
if (-not (Test-Path $EjectScriptPath)) {
    Write-Log "Không tìm thấy script EJECT: $EjectScriptPath. Bỏ qua bước EJECT." "WARN"
}
else {
    Write-Log "BẮT ĐẦU BƯỚC EJECT với script: $EjectScriptPath"

    $drvArgs = $PreparedTargets | ForEach-Object { $_.ToLower() }

    $ejectScriptFull = [System.IO.Path]::GetFullPath($EjectScriptPath)
    $argListEject = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $ejectScriptFull
    ) + $drvArgs

    & powershell.exe @argListEject
    $ejectCode = $LASTEXITCODE

    if ($ejectCode -ne 0) {
        Write-Log ("BƯỚC EJECT có lỗi (ExitCode={0})." -f $ejectCode) "ERROR"
    }
    else {
        Write-Log "BƯỚC EJECT hoàn tất."
    }
}

Write-Log "===== QUY TRÌNH HOÀN THÀNH ====="
Write-Host ""
Write-Host "Log file: $LogFile" -ForegroundColor Cyan
