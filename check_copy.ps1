param(
    # Thư mục nguồn (có thể chứa symlink/junction bên trong)
    [string]$SourceRoot  = ".\A Di Da Phat",

    # Danh sách ổ đích cần kiểm tra
    [string[]]$DestDrives = @("F:","G:","H:","I:","J:","K:","L:","M:")
)

Write-Host "===== KIỂM TRA COPY (chỉ file .mp3, có follow symlink/junction) =====" -ForegroundColor Cyan

# ---- Hàm lấy danh sách mp3, có follow symlink nếu PowerShell hỗ trợ ----
function Get-Mp3List {
    param(
        [string]$Root
    )

    # Chuẩn hoá đường dẫn tuyệt đối
    $rootFull = (Resolve-Path $Root).ProviderPath

    $params = @{
        Path    = $rootFull
        Filter  = '*.mp3'
        Recurse = $true
        File    = $true
        Force   = $true
    }

    # PowerShell 7+ hỗ trợ -FollowSymlink -> dùng nếu có
    $gciCmd = Get-Command Get-ChildItem
    if ($gciCmd.Parameters.ContainsKey('FollowSymlink')) {
        $params['FollowSymlink'] = $true
    }

    Get-ChildItem @params | ForEach-Object {
        # đường dẫn tương đối từ root
        $rel = $_.FullName.Substring($rootFull.Length).TrimStart('\')
        [PSCustomObject]@{
            FullName = $_.FullName
            RelPath  = $rel
            Length   = $_.Length
        }
    }
}

# -------- Lấy danh sách mp3 ở SOURCE (có follow symlink) --------

if (-not (Test-Path $SourceRoot)) {
    Write-Host "Thư mục nguồn không tồn tại: $SourceRoot" -ForegroundColor Red
    exit
}

Write-Host "Đang quét SOURCE: $SourceRoot" -ForegroundColor Cyan
$srcList  = Get-Mp3List -Root $SourceRoot
$srcCount = $srcList.Count
$srcSize  = ($srcList | Measure-Object Length -Sum).Sum

Write-Host "SOURCE: $srcCount file mp3, tổng dung lượng: $([math]::Round($srcSize/1MB,2)) MB"
Write-Host ""


# ================= CHECK TỪNG Ổ ĐÍCH =================

foreach ($drv in $DestDrives) {

    $destRoot = Join-Path $drv "A Di Da Phat"

    Write-Host "===== KIỂM TRA Ổ $drv =====" -ForegroundColor Yellow

    if (-not (Test-Path $destRoot)) {
        Write-Host "Không tìm thấy thư mục đích: $destRoot" -ForegroundColor Red
        continue
    }

    # Lấy danh sách mp3 ở DEST (toàn file thật)
    try {
        $destFull = (Resolve-Path $destRoot).ProviderPath
    }
    catch {
        Write-Host "Lỗi Resolve-Path cho đích ${destRoot}: $_" -ForegroundColor Red
        continue
    }

    $dstList = Get-ChildItem -Path $destFull -Filter *.mp3 -Recurse -File -Force |
        ForEach-Object {
            $rel = $_.FullName.Substring($destFull.Length).TrimStart('\')
            [PSCustomObject]@{
                FullName = $_.FullName
                RelPath  = $rel
                Length   = $_.Length
            }
        }

    $dstCount = $dstList.Count
    $dstSize  = ($dstList | Measure-Object Length -Sum).Sum

    Write-Host "DEST:   $dstCount file mp3, tổng dung lượng: $([math]::Round($dstSize/1MB,2)) MB"

    # ---- So sánh số lượng + tổng dung lượng ----
    if ($srcCount -eq $dstCount -and $srcSize -eq $dstSize) {
        Write-Host "✅ Ổ ${drv}: Số lượng & tổng dung lượng file mp3 KHỚP với source." -ForegroundColor Green
    } else {
        Write-Host "❌ Ổ ${drv}: KHÔNG KHỚP! (số file hoặc tổng dung lượng khác)" -ForegroundColor Red
    }

    # ---- So sánh chi tiết theo từng file (đường dẫn tương đối + size) ----

    # Map theo RelPath cho nhanh
    $srcMap = @{}
    foreach ($f in $srcList) {
        $srcMap[$f.RelPath.ToLower()] = $f
    }

    $dstMap = @{}
    foreach ($f in $dstList) {
        $dstMap[$f.RelPath.ToLower()] = $f
    }

    $onlyInSrc = @()
    $onlyInDst = @()
    $sizeDiff  = @()

    # File có ở source mà không có ở dest
    foreach ($rel in $srcMap.Keys) {
        if (-not $dstMap.ContainsKey($rel)) {
            $onlyInSrc += $rel
        } else {
            # Có cả 2 nhưng size khác => nghi ngờ copy lỗi / hỏng
            if ($srcMap[$rel].Length -ne $dstMap[$rel].Length) {
                $sizeDiff += [PSCustomObject]@{
                    RelPath    = $rel
                    SrcLength  = $srcMap[$rel].Length
                    DstLength  = $dstMap[$rel].Length
                }
            }
        }
    }

    # File có ở dest nhưng không có ở source (extra)
    foreach ($rel in $dstMap.Keys) {
        if (-not $srcMap.ContainsKey($rel)) {
            $onlyInDst += $rel
        }
    }

    if ($onlyInSrc.Count -eq 0 -and $onlyInDst.Count -eq 0 -and $sizeDiff.Count -eq 0) {
        Write-Host "👉 Chi tiết: Danh sách file mp3 & kích thước HOÀN TOÀN KHỚP." -ForegroundColor Green
    }
    else {
        Write-Host "👉 Chi tiết sai khác:" -ForegroundColor Yellow

        if ($onlyInSrc.Count -gt 0) {
            Write-Host "  - Có ở SOURCE nhưng thiếu ở DEST:" -ForegroundColor Red
            $onlyInSrc | Select-Object -First 20 | ForEach-Object { Write-Host "      $_" }
            if ($onlyInSrc.Count -gt 20) {
                Write-Host "      ... còn $($onlyInSrc.Count - 20) file nữa" -ForegroundColor DarkYellow
            }
        }

        if ($onlyInDst.Count -gt 0) {
            Write-Host "  - Chỉ có ở DEST (extra):" -ForegroundColor Magenta
            $onlyInDst | Select-Object -First 20 | ForEach-Object { Write-Host "      $_" }
            if ($onlyInDst.Count -gt 20) {
                Write-Host "      ... còn $($onlyInDst.Count - 20) file nữa" -ForegroundColor DarkYellow
            }
        }

        if ($sizeDiff.Count -gt 0) {
            Write-Host "  - File có đường dẫn giống nhau nhưng kích thước khác:" -ForegroundColor Red
            $sizeDiff | Select-Object RelPath,
                                      @{n='SrcKB';e={ [math]::Round($_.SrcLength/1KB,1) }},
                                      @{n='DstKB';e={ [math]::Round($_.DstLength/1KB,1) }} |
                        Format-Table -AutoSize
        }
    }

    Write-Host ""
}

pause
