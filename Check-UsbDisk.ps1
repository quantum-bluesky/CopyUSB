param(
    [ValidatePattern("^[A-Za-z]:?$")]
    [string[]]$DestDrives = @("F:", "G:", "H:", "I:", "J:", "K:", "L:", "M:"),

    [switch]$Fix,
    [switch]$NoConfirm,
    [switch]$NoPause,
    [string]$LogFile,

    [switch]$h,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[{0}] [DISKCHECK] [{1}] {2}" -f $timestamp, $Level.ToUpperInvariant(), $Message

    switch ($Level.ToUpperInvariant()) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN" { Write-Host $line -ForegroundColor Yellow }
        "INFO" { Write-Host $line -ForegroundColor Gray }
        default { Write-Host $line }
    }

    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        Add-Content -Path $LogFile -Value $line -Encoding utf8
    }
}

function Show-Help {
    $scriptName = if ($PSCommandPath) { Split-Path -Leaf $PSCommandPath } else { "Check-UsbDisk.ps1" }

    Write-Host "===== HUONG DAN SU DUNG: $scriptName =====" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Script kiem tra va sua loi he thong tep tren the nho/USB bang CHKDSK." -ForegroundColor Gray
    Write-Host ""
    Write-Host "Cu phap:" -ForegroundColor Yellow
    Write-Host "  .\${scriptName} -DestDrives F:,G:"
    Write-Host "  .\${scriptName} -DestDrives F: -Fix"
    Write-Host ""
    Write-Host "Tham so:" -ForegroundColor Yellow
    Write-Host "  -DestDrives <list> : Danh sach o can kiem tra."
    Write-Host "  -Fix               : Thu sua loi bang 'chkdsk /f /x' neu lan check dau bao co van de."
    Write-Host "  -NoConfirm         : Khong hoi lai cau hinh."
    Write-Host "  -NoPause           : Khong doi Enter cuoi script."
    Write-Host "  -LogFile <path>    : Ghi them log vao file."
    Write-Host "  -h / -Help         : Hien thi huong dan nay."
    Write-Host ""
    Write-Host "Ma thoat:" -ForegroundColor Yellow
    Write-Host "  0 = OK, khong thay loi"
    Write-Host "  1 = Da sua loi va check lai OK"
    Write-Host "  2 = Phat hien loi nhung chua sua (-Fix chua bat)"
    Write-Host "  3 = Da thu sua nhung van con loi"
    Write-Host "  4 = O khong san sang / khong ton tai"
    Write-Host "  5 = Loi khi goi CHKDSK"
    Write-Host "  6 = Can quyen Administrator de sua loi"
    Write-Host ""
}

function Normalize-DriveLetter {
    param([string]$Drive)

    return ($Drive.Trim().TrimEnd(':').ToUpperInvariant() + ':')
}

function Convert-ToComparableText {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return "" }

    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $normalized.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($category -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }

    return $sb.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Wait-DriveReady {
    param(
        [string]$DriveLetter,
        [int]$TimeoutSec = 20
    )

    $root = ($DriveLetter.TrimEnd(':') + ":\")
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $root) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    }

    return $false
}

function Get-DriveSummary {
    param([string]$DriveLetter)

    $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $DriveLetter) -ErrorAction SilentlyContinue
    if (-not $disk) { return $null }

    $driveTypeName = switch ([int]$disk.DriveType) {
        2 { "Removable" }
        3 { "Fixed" }
        4 { "Network" }
        5 { "CDROM" }
        default { "Other" }
    }

    [PSCustomObject]@{
        DeviceId   = $disk.DeviceID
        VolumeName = $disk.VolumeName
        FileSystem = $disk.FileSystem
        DriveType  = $driveTypeName
        SizeGB     = if ($disk.Size) { [Math]::Round(([double]$disk.Size / 1GB), 2) } else { 0 }
        FreeGB     = if ($disk.FreeSpace) { [Math]::Round(([double]$disk.FreeSpace / 1GB), 2) } else { 0 }
    }
}

function Invoke-Chkdsk {
    param(
        [string]$DriveLetter,
        [string[]]$Arguments
    )

    $argumentList = @($DriveLetter)
    if ($Arguments) {
        $argumentList += $Arguments
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "chkdsk.exe"
    $psi.Arguments = ($argumentList -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    [void]$proc.Start()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    $textParts = @()
    if (-not [string]::IsNullOrWhiteSpace($stdout)) { $textParts += $stdout.TrimEnd() }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { $textParts += $stderr.TrimEnd() }
    $combinedText = $textParts -join [Environment]::NewLine

    $lines = @()
    if (-not [string]::IsNullOrWhiteSpace($combinedText)) {
        $lines = $combinedText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Command  = ("chkdsk.exe {0}" -f ($argumentList -join ' '))
        Output   = $combinedText
        Lines    = @($lines)
    }
}

function Get-ChkdskAssessment {
    param(
        [pscustomobject]$Result,
        [switch]$FixMode
    )

    $text = Convert-ToComparableText -Text $Result.Output

    $failurePatterns = @(
        "access is denied",
        "khong du quyen truy cap",
        "cannot open volume for direct access",
        "khong the mo o dia de truy cap truc tiep",
        "the volume is in use by another process",
        "o dia dang duoc tien trinh khac su dung",
        "insufficient privileges",
        "khong du dac quyen"
    )

    $fixedPatterns = @(
        "made corrections to the file system",
        "windows has made corrections",
        "da sua loi he thong tep",
        "da sua chua he thong tep",
        "da thuc hien sua loi"
    )

    $issuePatterns = @(
        "found problems with the file system",
        "errors found",
        "found problems",
        "cannot continue in read-only mode",
        "khong the tiep tuc trong che do chi doc",
        "da tim thay loi",
        "he thong tep co van de",
        "run chkdsk with the /f",
        "hay chay chkdsk voi tham so /f"
    )

    $healthyPatterns = @(
        "found no problems",
        "no further action is required",
        "khong tim thay loi",
        "khong co van de nao",
        "khong can thuc hien them"
    )

    if ($FixMode) {
        foreach ($pattern in $fixedPatterns) {
            if ($text.Contains($pattern)) {
                return "Fixed"
            }
        }
    }

    foreach ($pattern in $issuePatterns) {
        if ($text.Contains($pattern)) {
            return "Issues"
        }
    }

    foreach ($pattern in $healthyPatterns) {
        if ($text.Contains($pattern)) {
            return "Healthy"
        }
    }

    if ($Result.ExitCode -eq 0) {
        return "Healthy"
    }

    foreach ($pattern in $failurePatterns) {
        if ($text.Contains($pattern)) {
            return "Failed"
        }
    }

    return "Issues"
}

function Write-ChkdskResult {
    param(
        [string]$DriveLetter,
        [string]$Label,
        [pscustomobject]$Result,
        [string]$Assessment
    )

    $level = switch ($Assessment) {
        "Healthy" { "INFO" }
        "Fixed" { "WARN" }
        "Issues" { "WARN" }
        default { "ERROR" }
    }

    Write-Log ("[{0}] {1} -> ExitCode={2}; Assessment={3}" -f $DriveLetter, $Label, $Result.ExitCode, $Assessment) $level

    $tail = @($Result.Lines | Select-Object -Last 8)
    foreach ($line in $tail) {
        Write-Log ("[{0}] {1}: {2}" -f $DriveLetter, $Label, $line) $level
    }
}

if ($h -or $Help) {
    Show-Help
    if (-not $NoPause) {
        Read-Host "Nhan Enter de thoat..." | Out-Null
    }
    exit 0
}

$DestDrives = $DestDrives | ForEach-Object { Normalize-DriveLetter $_ } | Select-Object -Unique

if ($Fix -and -not (Test-IsAdministrator)) {
    Write-Log "Can chay PowerShell voi quyen Administrator de sua loi the nho/USB." "ERROR"
    if (-not $NoPause) {
        Read-Host "Nhan Enter de thoat..." | Out-Null
    }
    exit 6
}

Write-Host "===== CAU HINH DISK CHECK =====" -ForegroundColor Cyan
Write-Host "DestDrives : $($DestDrives -join ', ')"
Write-Host "Fix        : $($Fix.IsPresent)"
Write-Host "LogFile    : $LogFile"
Write-Host ""

if ($Fix -and -not $NoConfirm) {
    Write-Host "Luu y: che do FIX se dismount o tam thoi bang 'chkdsk /f /x'." -ForegroundColor Yellow
}

if (-not $NoConfirm) {
    $confirm = Read-Host "Tiep tuc voi cau hinh tren? (Y/N, mac dinh = Y)"
    if ($confirm -and $confirm.Trim().ToUpperInvariant() -ne "Y") {
        Write-Log "Nguoi dung huy buoc DISKCHECK." "WARN"
        if (-not $NoPause) {
            Read-Host "Nhan Enter de thoat..." | Out-Null
        }
        exit 0
    }
}

$overallExitCode = 0
Write-Log "===== BAT DAU KIEM TRA THE NHO / USB ====="

foreach ($drive in $DestDrives) {
    Write-Log ("===== KIEM TRA O {0} =====" -f $drive)

    if (-not (Wait-DriveReady -DriveLetter $drive -TimeoutSec 5)) {
        Write-Log ("O {0} khong san sang hoac khong ton tai." -f $drive) "ERROR"
        if ($overallExitCode -lt 4) { $overallExitCode = 4 }
        continue
    }

    $summary = Get-DriveSummary -DriveLetter $drive
    if ($summary) {
        Write-Log ("[{0}] Type={1}; FS={2}; Label={3}; Size={4:N2}GB; Free={5:N2}GB" -f $drive, $summary.DriveType, $summary.FileSystem, $summary.VolumeName, $summary.SizeGB, $summary.FreeGB)
    }

    try {
        $checkResult = Invoke-Chkdsk -DriveLetter $drive -Arguments @()
        $checkAssessment = Get-ChkdskAssessment -Result $checkResult
        Write-ChkdskResult -DriveLetter $drive -Label "CHECK" -Result $checkResult -Assessment $checkAssessment
    }
    catch {
        Write-Log ("Loi khi chay CHKDSK cho {0}: {1}" -f $drive, $_.Exception.Message) "ERROR"
        if ($overallExitCode -lt 5) { $overallExitCode = 5 }
        continue
    }

    if ($checkAssessment -eq "Healthy") {
        Write-Log ("O {0} khong phat hien loi he thong tep." -f $drive)
        continue
    }

    if ($checkAssessment -eq "Failed") {
        Write-Log ("CHKDSK khong the kiem tra o {0}." -f $drive) "ERROR"
        if ($overallExitCode -lt 5) { $overallExitCode = 5 }
        continue
    }

    if (-not $Fix) {
        Write-Log ("O {0} co dau hieu loi. Chay lai voi -Fix de thu sua." -f $drive) "WARN"
        if ($overallExitCode -lt 2) { $overallExitCode = 2 }
        continue
    }

    try {
        $fixResult = Invoke-Chkdsk -DriveLetter $drive -Arguments @('/f', '/x')
        $fixAssessment = Get-ChkdskAssessment -Result $fixResult -FixMode
        Write-ChkdskResult -DriveLetter $drive -Label "FIX" -Result $fixResult -Assessment $fixAssessment
    }
    catch {
        Write-Log ("Loi khi sua CHKDSK cho {0}: {1}" -f $drive, $_.Exception.Message) "ERROR"
        if ($overallExitCode -lt 5) { $overallExitCode = 5 }
        continue
    }

    [void](Wait-DriveReady -DriveLetter $drive -TimeoutSec 20)

    try {
        $recheckResult = Invoke-Chkdsk -DriveLetter $drive -Arguments @()
        $recheckAssessment = Get-ChkdskAssessment -Result $recheckResult
        Write-ChkdskResult -DriveLetter $drive -Label "RECHECK" -Result $recheckResult -Assessment $recheckAssessment
    }
    catch {
        Write-Log ("Loi khi check lai {0}: {1}" -f $drive, $_.Exception.Message) "ERROR"
        if ($overallExitCode -lt 5) { $overallExitCode = 5 }
        continue
    }

    if ($recheckAssessment -eq "Healthy") {
        Write-Log ("Da sua xong loi he thong tep tren {0}." -f $drive) "WARN"
        if ($overallExitCode -lt 1) { $overallExitCode = 1 }
    }
    else {
        Write-Log ("Da thu sua {0} nhung van con loi hoac CHKDSK bao trang thai bat thuong." -f $drive) "ERROR"
        if ($overallExitCode -lt 3) { $overallExitCode = 3 }
    }
}

Write-Log ("===== DISKCHECK HOAN TAT. ExitCode={0} =====" -f $overallExitCode)

if (-not $NoPause) {
    Read-Host "Nhan Enter de thoat..." | Out-Null
}

exit $overallExitCode
