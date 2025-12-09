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
    [switch]$Help
)

function Show-Help {
    $scriptName = if ($PSCommandPath) { Split-Path $PSCommandPath -Leaf } else { "check_copy_symlink_hash.ps1" }

    Write-Host "===== HƯỚNG DẪN SỬ DỤNG: $scriptName =====" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Kiểm tra thư mục copy (chỉ file .mp3), có hỗ trợ symlink/junction, chạy song song." -ForegroundColor Gray
    Write-Host ""
    Write-Host "Cú pháp cơ bản:" -ForegroundColor Yellow
    Write-Host "  .\${scriptName}" -ForegroundColor White
    Write-Host ""
    Write-Host "Tham số:" -ForegroundColor Yellow
    Write-Host "  -SourceRoot  <path>      : Thư mục nguồn. Mặc định: .\A Di Da Phat"
    Write-Host "  -DestDrives  <list>      : Danh sách ổ cần check. Mặc định: F:..M:"
    Write-Host "  -Hash                    : Bật so sánh hash (mặc định OFF)."
    Write-Host "  -HashLastN  <N>          : Khi có -Hash:"
    Write-Host "                             =0  → hash toàn bộ file chung."
    Write-Host "                             >0  → chỉ hash N file cuối cùng."
    Write-Host "  -HashAlgorithm MD5|SHA256: Thuật toán hash (mặc định MD5)."
    Write-Host "  -h / -Help               : Hiển thị hướng dẫn này."
    Write-Host ""
    Write-Host "Ví dụ:" -ForegroundColor Yellow
    Write-Host "  # Check nhanh, không hash:"
    Write-Host "  .\${scriptName}"
    Write-Host ""
    Write-Host "  # Check nguồn D:\A Di Da Phat, 3 ổ F,G,H, hash toàn bộ:"
    Write-Host "  .\${scriptName} -SourceRoot 'D:\A Di Da Phat' -DestDrives F:,G:,H: -Hash"
    Write-Host ""
    Write-Host "  # Hash 200 file cuối cùng (ưu tiên phần copy sau cùng):"
    Write-Host "  .\${scriptName} -Hash -HashLastN 200"
    Write-Host ""
}

# --- Nếu người dùng gọi -h / -Help thì show hướng dẫn và dừng ---
if ($h -or $Help) {
    Show-Help
    return
}

Write-Host "===== KIỂM TRA COPY (mp3, follow symlink/junction) =====" -ForegroundColor Cyan
Write-Host "Source : $SourceRoot" -ForegroundColor Cyan
Write-Host "Drives : $($DestDrives -join ', ')" -ForegroundColor Cyan
if ($Hash) {
    if ($HashLastN -gt 0) {
        Write-Host "Hash   : ON ($HashAlgorithm), chỉ $HashLastN file cuối cùng" -ForegroundColor Cyan
    } else {
        Write-Host "Hash   : ON ($HashAlgorithm), toàn bộ file chung" -ForegroundColor Cyan
    }
} else {
    Write-Host "Hash   : OFF (chỉ check tên + kích thước file)" -ForegroundColor Cyan
}
Write-Host ""

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

    # PowerShell 7+ hỗ trợ -FollowSymlink
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

# -------- Kiểm tra tồn tại thư mục nguồn --------
if (-not (Test-Path $SourceRoot)) {
    Write-Host "❌ Thư mục nguồn KHÔNG tồn tại: $SourceRoot" -ForegroundColor Red
    Write-Host ""
    Show-Help
    return
}

# -------- Xác nhận cấu hình trước khi chạy --------
Write-Host "Cấu hình hiện tại:" -ForegroundColor Yellow
Write-Host "  SourceRoot : $SourceRoot"
Write-Host "  DestDrives : $($DestDrives -join ', ')"
Write-Host "  Hash       : $($Hash.IsPresent)"
Write-Host "  HashLastN  : $HashLastN"
Write-Host "  Algorithm  : $HashAlgorithm"
Write-Host ""

$confirm = Read-Host "Tiếp tục kiểm tra với cấu hình trên? (Y/N, mặc định = Y)"
if ($confirm -and $confirm.ToUpper() -ne 'Y') {
    Write-Host "Đã huỷ thao tác." -ForegroundColor Yellow
    return
}

# -------- SOURCE --------
Write-Host ""
Write-Host "Đang quét SOURCE: $SourceRoot" -ForegroundColor Cyan
$srcList  = Get-Mp3List -Root $SourceRoot
$srcCount = $srcList.Count
$srcSize  = ($srcList | Measure-Object Length -Sum).Sum

Write-Host "SOURCE: $srcCount file mp3, tổng dung lượng: $([math]::Round($srcSize/1MB,2)) MB"
Write-Host ""

# ================= CHẠY CHECK SONG SONG CÁC Ổ =================

$jobs = @()
$summaries = @()   # tổng kết theo ổ

foreach ($drv in $DestDrives) {
    $jobs += Start-Job -ArgumentList $drv, $SourceRoot, $srcList, $Hash, $HashAlgorithm, $HashLastN, $srcCount, $srcSize -ScriptBlock {
        param(
            $drv,
            $SourceRoot,
            $srcList,
            $Hash,
            $HashAlgorithm,
            $HashLastN,
            $srcCount,
            $srcSize
        )

        # --- chuẩn bị biến tổng kết ---
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
        }

        try {
            # Tạo map source theo RelPath
            $srcMap = @{}
            foreach ($f in $srcList) {
                $srcMap[$f.RelPath.ToLower()] = $f
            }
        }
        catch {
            Write-Host "[$drv] ❌ Lỗi khi chuẩn bị dữ liệu source: $_" -ForegroundColor Red
            $summary.Status       = "Error"
            $summary.ErrorMessage = "Lỗi chuẩn bị source: $_"
            Write-Output $summary
            return
        }

        $destRoot = Join-Path $drv "A Di Da Phat"

        Write-Host "===== KIỂM TRA Ổ $drv =====" -ForegroundColor Yellow

        if (-not (Test-Path $destRoot)) {
            Write-Host "[$drv] ❌ Không tìm thấy thư mục đích: $destRoot" -ForegroundColor Red
            $summary.Status       = "Error"
            $summary.ErrorMessage = "Không tìm thấy thư mục đích."
            Write-Output $summary
            return
        }

        try {
            $destFull = (Resolve-Path $destRoot).ProviderPath
        }
        catch {
            Write-Host "[$drv] ❌ Lỗi Resolve-Path cho đích ${destRoot}: $_" -ForegroundColor Red
            $summary.Status       = "Error"
            $summary.ErrorMessage = "Lỗi Resolve-Path: $_"
            Write-Output $summary
            return
        }

        # Danh sách mp3 ở DEST
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
            Write-Host "[$drv] ❌ Lỗi khi quét file mp3 ở đích: $_" -ForegroundColor Red
            $summary.Status       = "Error"
            $summary.ErrorMessage = "Lỗi Get-ChildItem đích: $_"
            Write-Output $summary
            return
        }

        $dstCount = $dstList.Count
        $dstSize  = ($dstList | Measure-Object Length -Sum).Sum

        Write-Host "[$drv] DEST: $dstCount file mp3, tổng dung lượng: $([math]::Round($dstSize/1MB,2)) MB"

        # ---- So sánh số lượng + tổng dung lượng ----
        if ($srcCount -eq $dstCount -and $srcSize -eq $dstSize) {
            Write-Host "[$drv] ✅ Số lượng & tổng dung lượng KHỚP với source." -ForegroundColor Green
        } else {
            Write-Host "[$drv] ❌ KHÔNG KHỚP (số file hoặc tổng dung lượng khác)" -ForegroundColor Red
        }

        # ---- So sánh chi tiết tên + size ----
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

        if ($onlyInSrc.Count -eq 0 -and $onlyInDst.Count -eq 0 -and $sizeDiff.Count -eq 0) {
            Write-Host "[$drv] 👉 Chi tiết: tên & kích thước file mp3 KHỚP." -ForegroundColor Green
        }
        else {
            Write-Host "[$drv] 👉 Chi tiết sai khác:" -ForegroundColor Yellow

            if ($onlyInSrc.Count -gt 0) {
                Write-Host "  [$drv] - Có ở SOURCE nhưng thiếu ở DEST:" -ForegroundColor Red
                $onlyInSrc | Select-Object -First 20 | ForEach-Object { Write-Host "      $_" }
                if ($onlyInSrc.Count -gt 20) {
                    Write-Host "      ... còn $($onlyInSrc.Count - 20) file nữa" -ForegroundColor DarkYellow
                }
            }

            if ($onlyInDst.Count -gt 0) {
                Write-Host "  [$drv] - Chỉ có ở DEST (extra):" -ForegroundColor Magenta
                $onlyInDst | Select-Object -First 20 | ForEach-Object { Write-Host "      $_" }
                if ($onlyInDst.Count -gt 20) {
                    Write-Host "      ... còn $($onlyInDst.Count - 20) file nữa" -ForegroundColor DarkYellow
                }
            }

            if ($sizeDiff.Count -gt 0) {
                Write-Host "  [$drv] - File đường dẫn giống nhưng kích thước khác:" -ForegroundColor Red
                $sizeDiff | Select-Object RelPath,
                                          @{n='SrcKB';e={ [math]::Round($_.SrcLength/1KB,1) }},
                                          @{n='DstKB';e={ [math]::Round($_.DstLength/1KB,1) }} |
                            Format-Table -AutoSize
            }
        }

        # Nếu không bật hash → kết luận & trả summary
        if (-not $Hash) {
            if ($summary.MissingCount -eq 0 -and
                $summary.ExtraCount   -eq 0 -and
                $summary.SizeDiffCount -eq 0) {
                $summary.Status = "OK"
            } else {
                $summary.Status = "Mismatch"
            }
            Write-Output $summary
            Write-Host ""
            return
        }

        # ================= HASH CHECK (tuỳ chọn) =================

        # Chỉ hash những file:
        # - có ở cả source & dest
        # - kích thước bằng nhau
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
            Write-Host "[$drv] ⚠ Không có file chung (cùng size) nào để hash." -ForegroundColor DarkYellow
            $summary.Status       = "Mismatch"
            $summary.ErrorMessage = "Không có file chung để hash."
            Write-Output $summary
            Write-Host ""
            return
        }

        # Sắp xếp và chọn file để hash (ưu tiên N file CUỐI)
        $filesToHash = $common | Sort-Object RelPath

        if ($HashLastN -gt 0 -and $HashLastN -lt $filesToHash.Count) {
            # dùng Last để ưu tiên file copy sau cùng
            $filesToHash = $filesToHash | Select-Object -Last $HashLastN
            Write-Host "[$drv] 🔍 Hash: đang kiểm tra $HashLastN file cuối cùng (tổng chung: $($common.Count))..." -ForegroundColor Cyan
        } else {
            Write-Host "[$drv] 🔍 Hash: đang kiểm tra TOÀN BỘ $($filesToHash.Count) file chung..." -ForegroundColor Cyan
        }

        $hashMismatch = @()
        $srcHashCache = @{}   # cache hash source theo FullName
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
                Write-Host "[$drv]  [$i/$total] Lỗi hash: $rel - $_" -ForegroundColor Red
                $summary.Status       = "Error"
                $summary.ErrorMessage = "Lỗi khi hash file."
                # Lỗi “cứng” khi hash → dừng, không xử lý tiếp
                Write-Output $summary
                Write-Host ""
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
                Write-Host "[$drv]  ... đã hash $i / $total file" -ForegroundColor DarkGray
            }
        }

        $summary.HashMismatchCount = $hashMismatch.Count

        if ($hashMismatch.Count -eq 0) {
            Write-Host "[$drv] ✅ Hash: tất cả file được kiểm tra đều KHỚP." -ForegroundColor Green
        } else {
            Write-Host "[$drv] ❌ Hash: phát hiện file KHÔNG KHỚP hash:" -ForegroundColor Red
            $hashMismatch | Select-Object -First 20 | Format-Table -AutoSize
            if ($hashMismatch.Count -gt 20) {
                Write-Host "  [$drv] ... còn $($hashMismatch.Count - 20) file mismatch nữa" -ForegroundColor DarkYellow
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
        Write-Host ""
    }
}

# ------ Nhận kết quả: ổ nào xong trước in trước ------
while ($jobs.Count -gt 0) {
    $finished = Wait-Job -Job $jobs -Any
    $results  = Receive-Job $finished   # sẽ in log theo thứ tự job hoàn thành
    # Lọc các object tổng kết
    $summaries += $results | Where-Object {
        $_ -is [pscustomobject] -and
        $_.PSObject.Properties.Name -contains 'Drive' -and
        $_.PSObject.Properties.Name -contains 'Status'
    }
    $jobs = $jobs | Where-Object { $_.Id -ne $finished.Id }
    Remove-Job $finished
}

# ------ Báo cáo tổng kết ------
Write-Host "===== TỔNG KẾT THEO Ổ =====" -ForegroundColor Cyan

if ($summaries.Count -eq 0) {
    Write-Host "Không thu được summary nào (có thể script bị lỗi trước khi chạy job)." -ForegroundColor Red
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
    }
}

Write-Host ""
Read-Host "Nhấn Enter để thoát..."
