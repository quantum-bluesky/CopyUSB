param(
    [array]$drive = @("f:","g:","h:","i:","j:","k:","l:","m:")
)

$err = $false

# Nếu không truyền tham số thì dùng list mặc định ở trên
if (-not $args -or -not $args[0]) {
    $args = $drive
}

# Chuẩn hoá & kiểm tra ổ đĩa tồn tại
$drvList = @()
for ($i = 0; $i -lt $args.Length; $i++) {
    if ($null -eq $args[$i] -or $args[$i] -eq "") {
        Write-Host "Please input drive to Eject!" -ForegroundColor Yellow
        $err = $true
        continue
    }

    $drv = $args[$i].Trim("\")
    try {
        if (-not (Test-Path "$drv\")) {
            Write-Host "Eject drive '$drv' is not exist!" -ForegroundColor Red
            $err = $true
            continue
        }
    }
    catch {
        Write-Host "Error when checking drive '$drv': $_" -ForegroundColor Red
        $err = $true
        continue
    }

    $drvList += $drv
}

if ($drvList.Count -eq 0) {
    if ($err) {
        pause
    }
    exit
}

# ========= EJECT SONG SONG + RETRY =========
# Mỗi ổ sẽ chạy trong một Job riêng => song song
$jobs = @()

foreach ($drv in $drvList) {
    $jobs += Start-Job -ArgumentList $drv -ScriptBlock {
        param($drv)

        # Số lần retry tối đa & thời gian chờ giữa mỗi lần
        $maxRetries   = 5      # chỉnh tuỳ bạn, muốn "vô hạn" có thể đổi logic thành while ($true)
        $delaySeconds = 2
        $drivePath    = "$drv\"

        Write-Host "[$drv] Bắt đầu eject..." -ForegroundColor Cyan

        $driveEject = New-Object -ComObject Shell.Application

        for ($try = 1; $try -le $maxRetries; $try++) {

            # Nếu ổ đã biến mất thì coi như eject xong
            if (-not (Test-Path $drivePath)) {
                Write-Host "[$drv] Ổ đã không còn tồn tại (coi như đã eject / rút ra)." -ForegroundColor Green
                break
            }

            try {
                $item = $driveEject.Namespace(17).ParseName($drv)
                if ($null -eq $item) {
                    Write-Host "[$drv] Không tìm thấy trong Shell namespace, coi như đã eject." -ForegroundColor Green
                    break
                }

                # Lệnh eject chính
                $item.InvokeVerb("Eject")
            }
            catch {
                Write-Host "[$drv] Lỗi khi eject (lần $try): $_" -ForegroundColor Red
            }

            # Chờ một chút rồi kiểm tra lại
            Start-Sleep -Seconds $delaySeconds

            if (-not (Test-Path $drivePath)) {
                Write-Host "[$drv] Eject thành công sau $try lần thử." -ForegroundColor Green
                break
            }
            else {
                Write-Host "[$drv] Vẫn chưa eject được, thử lại ($try/$maxRetries)..." -ForegroundColor Yellow
            }
        }

        # Sau maxRetries lần mà vẫn còn ổ thì báo thất bại
        if (Test-Path $drivePath) {
            Write-Host "[$drv] Hết $maxRetries lần thử nhưng vẫn chưa eject được." -ForegroundColor Red
        }
    }
}

# Đợi tất cả job eject xong
Wait-Job -Job $jobs | Out-Null
Receive-Job -Job $jobs | Out-Null
Remove-Job -Job $jobs

if ($error -or $err) {
    if ($error -ne '') {
        Write-Host "Error: $error" -ForegroundColor Red
    }
}

pause
