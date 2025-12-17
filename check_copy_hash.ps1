param(
    # Thư mục nguồn (có thể chứa symlink/junction bên trong)
    [string]$SourceRoot  = ".\A Di Da Phat",

    # Danh sách ổ đích cần kiểm tra
    [string[]]$DestDrives = @("F:","G:","H:","I:","J:","K:","L:","M:"),

    # Bật so sánh hash (mặc định KHÔNG hash để chạy nhanh)
    [switch]$Hash,

    # Nếu > 0: chỉ hash N file cuối cùng (sorted theo đường dẫn tương đối)
    # Nếu = 0: hash toàn bộ file chung (cùng size)
    [int]$HashLastN = 0,

    # Thuật toán hash
    [ValidateSet('MD5','SHA256')]
    [string]$HashAlgorithm = 'MD5',

    # Hiển thị hướng dẫn
    [switch]$h,
    [switch]$Help,

    # Không hỏi confirm config
    [switch]$NoConfirm,

    # Không pause cuối cùng (dùng khi gọi từ master)
    [switch]$NoPause,

    # Ghi log vào file (nếu có)
    [string]$LogFile
)

Set-StrictMode -Version Latest

# ---------- HÀM LOG ----------
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[{0}] [CHECK] [{1}] {2}" -f $timestamp, $Level.ToUpper(), $Message

    switch ($Level.ToUpper()) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "INFO"  { Write-Host $line -ForegroundColor Gray }
        default { Write-Host $line }
    }

    if ($LogFile) {
        Add-Content -Path $LogFile -Value $line -Encoding utf8
    }
}

function Show-Help {
    $scriptName = if ($PSCommandPath) { Split-Path $PSCommandPath -Leaf } else { "check_copy_symlink_hash.ps1" }

    Write-Host "===== HƯỚNG DẪN SỬ DỤNG: $scriptName =====" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Kiểm tra thư mục copy (chỉ file .mp3), có hỗ trợ symlink/junction, chạy song song." -ForegroundColor Gray
    Write-Host ""
    Write-Host "Cú pháp cơ bản:" -ForegroundColor Yellow
    Write-Host "  .\${scriptName}"
    Write-Host ""
    Write-Host "Tham số:" -ForegroundColor Yellow
    Write-Host "  -SourceRoot  <path>      : Thư mục nguồn. Mặc định: .\A Di Da Phat"
    Write-Host "  -DestDrives  <list>      : Danh sách ổ cần check. Mặc định: F:..M:"
    Write-Host "  -Hash                    : Bật so sánh hash (mặc định OFF)."
    Write-Host "  -HashLastN  <N>          : Khi có -Hash:"
    Write-Host "                             =0  → hash toàn bộ file chung."
    Write-Host "                             >0  → chỉ hash N file cuối cùng."
    Write-Host "  -HashAlgorithm MD5|SHA256: Thuật toán hash (mặc định MD5)."
    Write-Host "  -NoConfirm               : Không hỏi lại cấu hình."
    Write-Host "  -NoPause                 : Không chờ Enter cuối script."
    Write-Host "  -LogFile     <path>      : Ghi log vào file chỉ định."
    Write-Host "  -h / -Help               : Hiển thị hướng dẫn này."
    Write-Host ""
    Write-Host "Ví dụ:" -ForegroundColor Yellow
    Write-Host "  .\${scriptName} -SourceRoot 'D:\A Di Da Phat' -DestDrives F:,G:,H: -Hash -HashLastN 200"
    Write-Host ""
}

if ($h -or $Help) {
    Show-Help
    if (-not $NoPause) { Read-Host "Nhấn Enter để thoát..." | Out-Null }
    exit 0
}

Write-Log "===== BẮT ĐẦU BƯỚC CHECK ====="

if (-not (Test-Path $SourceRoot)) {
    Write-Log "Thư mục nguồn không tồn tại: $SourceRoot" "ERROR"
    if (-not $NoPause) { Read-Host "Nhấn Enter để thoát..." | Out-Null }
    exit 1
}

# Chuẩn hoá ổ
$DestDrives = $DestDrives | ForEach-Object {
    ($_ -replace '\\','').TrimEnd(':') + ':'
} | Select-Object -Unique

Write-Host "===== CẤU HÌNH CHECK =====" -ForegroundColor Cyan
Write-Host "SourceRoot    : $SourceRoot"
Write-Host "DestDrives    : $($DestDrives -join ', ')"
Write-Host "Hash          : $($Hash.IsPresent)"
Write-Host "HashLastN     : $HashLastN"
Write-Host "HashAlgorithm : $HashAlgorithm"
Write-Host "LogFile       : $LogFile"
Write-Host ""

if (-not $NoConfirm) {
    $ans = Read-Host "Tiếp tục với cấu hình trên? (Y/N, mặc định = Y)"
    if ($ans -and $ans.ToUpper() -ne 'Y') {
        Write-Log "Người dùng hủy bước CHECK." "WARN"
        if (-not $NoPause) { Read-Host "Nhấn Enter để thoát..." | Out-Null }
        exit 0
    }
}

# ---- Hàm lấy danh sách mp3, có follow symlink nếu PowerShell hỗ trợ ----
function Get-Mp3List {
    param(
        [string]$Root
    )

    $rootFull = (Resolve-Path $Root).ProviderPath

    $params = @{
        Path    = $rootFull
        Filter  = '*.mp3'
        Recurse = $true
        File    = $true
        Force   = $true
    }

    $gciCmd = Get-Command Get-ChildItem
    if ($gciCmd.Parameters.ContainsKey('FollowSymlink')) {
        $params['FollowSymlink'] = $true
    }

    Get-ChildItem @params | ForEach-Object {
        $rel = $_.FullName.Substring($rootFull.Length).TrimStart('\')
        [PSCustomObject]@{
            FullName = $_.FullName
            RelPath  = $rel
            Length   = $_.Length
        }
    }
}

# -------- SOURCE --------
Write-Log "Đang quét SOURCE: $SourceRoot"
$srcList  = Get-Mp3List -Root $SourceRoot
$srcCount = $srcList.Count
$srcSize  = ($srcList | Measure-Object Length -Sum).Sum

Write-Log ("SOURCE: {0} file mp3, ~{1:N2} MB" -f $srcCount, ($srcSize/1MB))

$jobs = @()
$summaries = @()

foreach ($drv in $DestDrives) {
    $jobs += Start-Job -ArgumentList $drv, $SourceRoot, $srcList, $Hash, $HashAlgorithm, $HashLastN, $srcCount, $srcSize, $LogFile -ScriptBlock {
        param(
            $drv,
            $SourceRoot,
            $srcList,
            $Hash,
            $HashAlgorithm,
            $HashLastN,
            $srcCount,
            $srcSize,
            $LogFile
        )

        Set-StrictMode -Version Latest

        function Write-LogLocal {
            param(
                [string]$Message,
                [string]$Level = "INFO"
            )
            $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $line = "[{0}] [CHECK] [{1}] {2}" -f $timestamp, $Level.ToUpper(), $Message

            switch ($Level.ToUpper()) {
                "ERROR" { Write-Host $line -ForegroundColor Red }
                "WARN"  { Write-Host $line -ForegroundColor Yellow }
                "INFO"  { Write-Host $line -ForegroundColor Gray }
                default { Write-Host $line }
            }

            if ($LogFile) {
                Add-Content -Path $LogFile -Value $line -Encoding utf8
            }
        }

        $summary = [PSCustomObject]@{
            Drive            = $drv
            Status           = "Unknown"
            ErrorMessage     = ""
            MissingCount     = 0
            ExtraCount       = 0
            SizeDiffCount    = 0
            HashEnabled      = [bool]$Hash
            HashCheckedCount = 0
            HashMismatchCount= 0
            MissingParentsAllEmpty    = $true
            MissingParentsAnyHasFiles = $false
        }

        $detailLogLimit = 100

        try {
            $srcMap = @{}
            foreach ($f in $srcList) {
                $srcMap[$f.RelPath.ToLower()] = $f
            }
        }
        catch {
            Write-LogLocal "[$drv] Lỗi khi chuẩn bị dữ liệu source: $_" "ERROR"
            $summary.Status       = "Error"
            $summary.ErrorMessage = "Lỗi chuẩn bị source: $_"
            Write-Output $summary
            return
        }

        $destRoot = Join-Path $drv (Split-Path $SourceRoot -Leaf)

        Write-LogLocal "===== KIỂM TRA Ổ $drv (dest: $destRoot) ====="

        if (-not (Test-Path $destRoot)) {
            Write-LogLocal "[$drv] Thư mục đích không tồn tại: $destRoot" "ERROR"
            $summary.Status       = "Error"
            $summary.ErrorMessage = "Thư mục đích không tồn tại."
            Write-Output $summary
            return
        }

        try {
            $destFull = (Resolve-Path $destRoot).ProviderPath
        }
        catch {
            Write-LogLocal "[$drv] Lỗi Resolve-Path cho đích: $_" "ERROR"
            $summary.Status       = "Error"
            $summary.ErrorMessage = "Lỗi Resolve-Path."
            Write-Output $summary
            return
        }

        try {
            $dstList = Get-ChildItem -Path $destFull -Filter *.mp3 -Recurse -File -Force |
                ForEach-Object {
                    $rel = $_.FullName.Substring($destFull.Length).TrimStart('\')
                    [PSCustomObject]@{
                        FullName = $_.FullName
                        RelPath  = $rel
                        Length   = $_.Length
                    }
                }
        }
        catch {
            Write-LogLocal "[$drv] Lỗi quét file mp3 ở đích: $_" "ERROR"
            $summary.Status       = "Error"
            $summary.ErrorMessage = "Lỗi Get-ChildItem đích."
            Write-Output $summary
            return
        }

        $dstCount = $dstList.Count
        $dstSize  = ($dstList | Measure-Object Length -Sum).Sum

        Write-LogLocal ("[$drv] DEST: {0} file mp3, ~{1:N2} MB" -f $dstCount, ($dstSize/1MB))

        if ($srcCount -eq $dstCount -and $srcSize -eq $dstSize) {
            Write-LogLocal "[$drv] Số lượng & tổng dung lượng KHỚP với source."
        } else {
            Write-LogLocal "[$drv] KHÔNG KHỚP (số file hoặc tổng dung lượng khác)." "WARN"
        }

        $dstMap = @{}
        foreach ($f in $dstList) {
            $dstMap[$f.RelPath.ToLower()] = $f
        }

        $onlyInSrc = @()
        $onlyInDst = @()
        $sizeDiff  = @()

        foreach ($rel in $srcMap.Keys) {
            if (-not $dstMap.ContainsKey($rel)) {
                $onlyInSrc += $rel
            } else {
                if ($srcMap[$rel].Length -ne $dstMap[$rel].Length) {
                    $sizeDiff += [PSCustomObject]@{
                        RelPath    = $rel
                        SrcLength  = $srcMap[$rel].Length
                        DstLength  = $dstMap[$rel].Length
                    }
                }
            }
        }

        foreach ($rel in $dstMap.Keys) {
            if (-not $srcMap.ContainsKey($rel)) {
                $onlyInDst += $rel
            }
        }

        $summary.MissingCount  = $onlyInSrc.Count
        $summary.ExtraCount    = $onlyInDst.Count
        $summary.SizeDiffCount = $sizeDiff.Count

        # Phân loại missing: thư mục cha có file trực tiếp hay không
        if ($onlyInSrc.Count -gt 0) {
            $parents = $onlyInSrc | ForEach-Object { Split-Path -Path $_ -Parent } | Sort-Object -Unique
            $allEmpty = $true
            $anyHasFile = $false
            foreach ($parentRel in $parents) {
                $parentDest = if ([string]::IsNullOrEmpty($parentRel)) { $destFull } else { Join-Path $destFull $parentRel }
                try {
                    $hasDirect = (Get-ChildItem -Path $parentDest -File -Force -ErrorAction Stop | Select-Object -First 1)
                    if ($hasDirect) {
                        $anyHasFile = $true
                        $allEmpty = $false
                        break
                    }
                }
                catch {
                    # Nếu thư mục cha không tồn tại, xem như không có file trực tiếp
                    continue
                }
            }
            $summary.MissingParentsAllEmpty    = $allEmpty
            $summary.MissingParentsAnyHasFiles = $anyHasFile
        }

        if ($onlyInSrc.Count -eq 0 -and $onlyInDst.Count -eq 0 -and $sizeDiff.Count -eq 0) {
            Write-LogLocal "[$drv] Chi tiết: tên & kích thước file mp3 KHỚP."
        } else {
            Write-LogLocal "[$drv] Chi tiết sai khác:" "WARN"

            if ($onlyInSrc.Count -gt 0) {
                Write-LogLocal "[$drv]  - Có ở SOURCE nhưng thiếu ở DEST: $($onlyInSrc.Count) file." "WARN"
                if ($onlyInSrc.Count -lt $detailLogLimit) {
                    $onlyInSrc | Sort-Object | ForEach-Object {
                        Write-LogLocal "[$drv]    SOURCE-only: $_" "WARN"
                    }
                }
            }
            if ($onlyInDst.Count -gt 0) {
                Write-LogLocal "[$drv]  - Chỉ có ở DEST (extra): $($onlyInDst.Count) file." "WARN"
                if ($onlyInDst.Count -lt $detailLogLimit) {
                    $onlyInDst | Sort-Object | ForEach-Object {
                        Write-LogLocal "[$drv]    DEST-only: $_" "WARN"
                    }
                }
            }
            if ($sizeDiff.Count -gt 0) {
                Write-LogLocal "[$drv]  - File đường dẫn giống nhưng kích thước khác: $($sizeDiff.Count) file." "WARN"
                if ($sizeDiff.Count -lt $detailLogLimit) {
                    $sizeDiff | Sort-Object RelPath | ForEach-Object {
                        Write-LogLocal ("[$drv]    Size diff: {0} (src={1} dst={2})" -f $_.RelPath, $_.SrcLength, $_.DstLength) "WARN"
                    }
                }
            }
        }

        if (-not $Hash) {
            if ($summary.MissingCount -eq 0 -and
                $summary.ExtraCount   -eq 0 -and
                $summary.SizeDiffCount -eq 0) {
                $summary.Status = "OK"
            } else {
                $summary.Status = "Mismatch"
            }
            Write-Output $summary
            return
        }

        if ($summary.SizeDiffCount -gt 0) {
            Write-LogLocal "[$drv] Bỏ qua hash do có $($summary.SizeDiffCount) file lệch dung lượng." "WARN"
            $summary.Status = "Mismatch"
            Write-Output $summary
            return
        }

        # ================= HASH CHECK =================

        $common = @()
        foreach ($rel in $srcMap.Keys) {
            if ($dstMap.ContainsKey($rel)) {
                if ($srcMap[$rel].Length -eq $dstMap[$rel].Length) {
                    $common += [PSCustomObject]@{
                        RelPath = $rel
                        Src     = $srcMap[$rel].FullName
                        Dst     = $dstMap[$rel].FullName
                        Length  = $srcMap[$rel].Length
                    }
                }
            }
        }

        if ($common.Count -eq 0) {
            Write-LogLocal "[$drv] Không có file chung (cùng size) nào để hash." "WARN"
            $summary.Status       = "Mismatch"
            $summary.ErrorMessage = "Không có file chung để hash."
            Write-Output $summary
            return
        }

        $filesToHash = $common | Sort-Object RelPath

        if ($HashLastN -gt 0 -and $HashLastN -lt $filesToHash.Count) {
            $filesToHash = $filesToHash | Select-Object -Last $HashLastN
            Write-LogLocal "[$drv] Hash: kiểm tra $HashLastN file cuối cùng (tổng chung: $($common.Count))."
        } else {
            Write-LogLocal "[$drv] Hash: kiểm tra TOÀN BỘ $($filesToHash.Count) file chung."
        }

        $hashMismatch = @()
        $srcHashCache = @{}
        $total        = $filesToHash.Count
        $summary.HashCheckedCount = $total

        $i = 0
        foreach ($item in $filesToHash) {
            $i++
            $rel = $item.RelPath

            try {
                if (-not $srcHashCache.ContainsKey($item.Src)) {
                    $srcHashCache[$item.Src] = (Get-FileHash -Path $item.Src -Algorithm $HashAlgorithm).Hash
                }
                $srcHash = $srcHashCache[$item.Src]
                $dstHash = (Get-FileHash -Path $item.Dst -Algorithm $HashAlgorithm).Hash
            }
            catch {
                Write-LogLocal "[$drv] Lỗi hash file: $rel - $_" "ERROR"
                $summary.Status       = "Error"
                $summary.ErrorMessage = "Lỗi khi hash file."
                Write-Output $summary
                return
            }

            if ($srcHash -ne $dstHash) {
                $hashMismatch += [PSCustomObject]@{
                    RelPath = $rel
                    SrcHash = $srcHash
                    DstHash = $dstHash
                }
            }

            if ($i % 100 -eq 0) {
                Write-LogLocal "[$drv]  ... đã hash $i / $total file."
            }
        }

        $summary.HashMismatchCount = $hashMismatch.Count

        if ($hashMismatch.Count -eq 0) {
            Write-LogLocal "[$drv] Hash: tất cả file được kiểm tra đều KHỚP."
        } else {
            Write-LogLocal "[$drv] Hash: phát hiện $($hashMismatch.Count) file KHÔNG KHỚP hash." "ERROR"
            if ($hashMismatch.Count -lt $detailLogLimit) {
                $hashMismatch | Sort-Object RelPath | ForEach-Object {
                    Write-LogLocal ("[$drv]    Hash mismatch: {0} (src={1} dst={2})" -f $_.RelPath, $_.SrcHash, $_.DstHash) "WARN"
                }
            }
        }

        if ($summary.MissingCount -eq 0 -and
            $summary.ExtraCount   -eq 0 -and
            $summary.SizeDiffCount -eq 0 -and
            $summary.HashMismatchCount -eq 0) {
            $summary.Status = "OK"
        } else {
            $summary.Status = "Mismatch"
        }

        Write-Output $summary
    }
}

while (@($jobs).Count -gt 0) {
    $finished = Wait-Job -Job $jobs -Any
    $results  = Receive-Job $finished
    $summaries += $results | Where-Object {
        $_ -is [pscustomobject] -and
        $_.PSObject.Properties.Name -contains 'Drive' -and
        $_.PSObject.Properties.Name -contains 'Status'
    }
    $jobs = @($jobs | Where-Object { $_.Id -ne $finished.Id })
    Remove-Job $finished
}

Write-Host ""
Write-Host "===== TỔNG KẾT CHECK =====" -ForegroundColor Cyan

$overallOK = $true
$exitCode  = 0

if ($summaries.Count -eq 0) {
    Write-Log "Không thu được summary nào từ job." "ERROR"
    $overallOK = $false
    $exitCode  = 1
} else {
    $summaries | Sort-Object Drive | ForEach-Object {
        $d = $_
        $color = switch ($d.Status) {
            "OK"       { "Green" }
            "Mismatch" { "Yellow" }
            "Error"    { "Red" }
            default    { "Gray" }
        }

        Write-Host ("Ổ {0}: {1}" -f $d.Drive, $d.Status) -ForegroundColor $color
        if ($d.ErrorMessage) {
            Write-Host ("  Lỗi   : {0}" -f $d.ErrorMessage) -ForegroundColor Red
        }
        if ($d.MissingCount -gt 0 -or $d.ExtraCount -gt 0 -or $d.SizeDiffCount -gt 0) {
            Write-Host ("  Thiếu : {0}, Thừa : {1}, Size lệch : {2}" -f $d.MissingCount, $d.ExtraCount, $d.SizeDiffCount) -ForegroundColor Yellow
        }
        if ($d.HashEnabled) {
            Write-Host ("  Hash  : đã check {0} file, mismatch: {1}" -f $d.HashCheckedCount, $d.HashMismatchCount) -ForegroundColor Gray
        }

        if ($d.Status -eq "Error") {
            $exitCode  = [Math]::Max($exitCode, 1)
            $overallOK = $false
        } elseif ($d.MissingCount -gt 0) {
            if ($d.MissingParentsAnyHasFiles) {
                $exitCode = [Math]::Max($exitCode, 5)
            } else {
                $exitCode = [Math]::Max($exitCode, 4)
            }
            $overallOK = $false
        } elseif ($d.ExtraCount -gt 0) {
            $exitCode  = [Math]::Max($exitCode, 3)
            $overallOK = $false
        } elseif ($d.SizeDiffCount -gt 0 -or $d.HashMismatchCount -gt 0) {
            $exitCode  = [Math]::Max($exitCode, 2)
            $overallOK = $false
        } elseif ($d.Status -ne "OK") {
            $exitCode  = [Math]::Max($exitCode, 1)
            $overallOK = $false
        }
    }
}

if (-not $NoPause) {
    Read-Host "Nhấn Enter để thoát..." | Out-Null
}

if (-not $overallOK) {
    exit $exitCode
}

exit 0
