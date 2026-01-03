param(
    # Thư mục nguồn cần copy (chứa dữ liệu gốc)
    [ValidateNotNullOrEmpty()]
    [string]$SourceRoot = "D:\A Di Da Phat",

    # Danh sách ổ đích (USB) cần xử lý
    [ValidateNotNullOrEmpty()]
    [string[]]$DestDrives = @("F:", "G:", "H:", "I:", "J:", "K:", "L:", "M:"),

    # Đường dẫn script CHECK
    [ValidateNotNullOrEmpty()]
    [string]$CheckScriptPath = ".\check_copy_hash.ps1",
    # Đường dẫn script SORT (Mp3FatSort)
    [string]$SortScriptPath = ".\Mp3FatSort.ps1",

    # Tự động check & sort sau khi copy - check xong
    [bool]$CheckAndSort = $true,


    # Tham số cho bước CHECK
    [switch]$EnableHash = $true,       # bật check hash
    [int]$HashLastN = 100,     # số file cuối cùng để hash (0 = hash toàn bộ)
    [ValidateSet('CRC32', 'MD5', 'SHA256')]
    [string]$HashAlgorithm = 'MD5',

    # Đường dẫn script EJECT
    [string]$EjectScriptPath = ".\removedrv.ps1",

    # Đường dẫn script remount USB (dùng để capture / remount)
    [string]$RemountScriptPath = ".\Remount-Usb.ps1",
    [string]$RemountCachePath  = ".\usb_remount_cache.json",

    # Thư mục log
    [ValidateNotNullOrEmpty()]
    [string]$LogDir = ".\logs",

    # Không hỏi confirm (auto yes)
    # Khong hoi confirm (auto yes)
    [switch]$AutoYes,

    # Bo qua buoc Eject
    [switch]$SkipEject
)

Set-StrictMode -Version Latest

$script:DriveLogFiles = @{}
$script:DriveLogStates = @{}
$script:EarlyCopyErrors = @{}
$script:CopySpeedStates = @{}
$script:CopyAbortReasons = @{}
$script:StartCopyErrors = @{}

$PreparedTargets = @()
$MirrorTargets = @()

$script:WriteTestMinBytes = 4096
$script:WriteTestMaxBytes = 16384
$script:CopyNoProgressSec = 90
$script:CopyNoProgressDeltaBytes = 4096

# Chạy với quyền Administrator
# Kiểm tra quyền admin
$windowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$windowsPrincipal = New-Object Security.Principal.WindowsPrincipal($windowsIdentity)
$adminRole = [Security.Principal.WindowsBuiltinRole]::Administrator

if (-not $windowsPrincipal.IsInRole($adminRole)) {
    Write-Host "Script dang chay khong co quyen Administrator." -ForegroundColor Yellow
    $runAsAdmin = $false
    if (-not $AutoYes) {
        $ans = Read-Host "Chay lai voi quyen Administrator? (Y/N, mac dinh = N)"
        if ($ans -and $ans.Trim().ToUpper() -eq "Y") {
            $runAsAdmin = $true
        }
    } else {
        Write-Host "AutoYes dang bat -> tiep tuc chay khong co quyen Admin." -ForegroundColor Yellow
    }

    if ($runAsAdmin) {
        $scriptPath = $MyInvocation.MyCommand.Path
        $allArgs = @()
        foreach ($param in $PSBoundParameters.Keys) {
            $value = $PSBoundParameters[$param]
            if ($value -is [switch]) {
                if ($value.IsPresent) { $allArgs += "-$param" }
            }
            elseif ($value -is [System.Array]) {
                foreach ($item in $value) {
                    $allArgs += "-$param"
                    $allArgs += "$item"
                }
            }
            else {
                $allArgs += "-$param"
                $allArgs += "$value"
            }
        }

        $shellExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { "pwsh.exe" } else { "powershell.exe" }
        $baseArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath)
        Start-Process $shellExe -ArgumentList ($baseArgs + $allArgs) -Verb RunAs
        exit
    }
}


# Ghi nhan trang thai tham so/duong dan truoc khi chuan hoa
$script:SkipEjectEffective = $SkipEject
$script:CheckPathIsEmpty = [string]::IsNullOrWhiteSpace($CheckScriptPath)
$script:SortScriptIsEmpty = [string]::IsNullOrWhiteSpace($SortScriptPath)
$script:EjectPathIsEmpty = [string]::IsNullOrWhiteSpace($EjectScriptPath)
$script:RemountScriptIsEmpty = [string]::IsNullOrWhiteSpace($RemountScriptPath)
$script:RemountCacheIsEmpty  = [string]::IsNullOrWhiteSpace($RemountCachePath)
$script:LogDirIsEmpty        = [string]::IsNullOrWhiteSpace($LogDir)

if ($script:EjectPathIsEmpty) {
    $script:SkipEjectEffective = $true
}
# Gốc thực thi (để xử lý đường dẫn tương đối khi chạy từ cwd khác)
$ScriptDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).ProviderPath }

# Chuẩn hoá đường dẫn tương đối thành tuyệt đối (dựa trên thư mục script)
if (-not $script:CheckPathIsEmpty -and -not [System.IO.Path]::IsPathRooted($CheckScriptPath)) {
    $CheckScriptPath = Join-Path $ScriptDir $CheckScriptPath
}
if (-not $script:SortScriptIsEmpty -and -not [System.IO.Path]::IsPathRooted($SortScriptPath)) {
    $SortScriptPath = Join-Path $ScriptDir $SortScriptPath
}
if (-not $script:SkipEjectEffective -and -not $script:EjectPathIsEmpty -and -not [System.IO.Path]::IsPathRooted($EjectScriptPath)) {
    $EjectScriptPath = Join-Path $ScriptDir $EjectScriptPath
}
if (-not $script:RemountScriptIsEmpty -and -not [System.IO.Path]::IsPathRooted($RemountScriptPath)) {
    $RemountScriptPath = Join-Path $ScriptDir $RemountScriptPath
}
if (-not $script:RemountCacheIsEmpty -and -not [System.IO.Path]::IsPathRooted($RemountCachePath)) {
    $RemountCachePath = Join-Path $ScriptDir $RemountCachePath
}
if (-not $script:LogDirIsEmpty -and -not [System.IO.Path]::IsPathRooted($LogDir)) {
    $LogDir = Join-Path $ScriptDir $LogDir
}
# Kiểm tra quyền admin (phục vụ cảnh báo remount)
$script:IsAdmin = $false
try {

    $letter = $drv.TrimEnd(':')

    Write-Log ("Dang format {0} (cluster {1}KB) o {2}..." -f $fsType, ($clusterSize / 1KB), $drv) "WARN" -Drive $drv

    Format-Volume -DriveLetter $letter -FileSystem $fsType -AllocationUnitSize $clusterSize -NewFileSystemLabel "USB_$letter" -Confirm:$false -Force -ErrorAction Stop

    Write-Log ("Da quick format {0} (cluster {1}KB) o {2}." -f $fsType, ($clusterSize / 1KB), $drv) -Drive $drv


    # Cho ? mount l?i

    if (-not (Wait-DriveReady $drv 30)) {

        Write-Log "Sau khi format, ? $drv khong ready trong 30s. B? QUA ? nay." "ERROR" -Drive $drv

        continue

    }


    $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drv)

    $totalSize = [double]$disk.Size

    $freeSpace = [double]$disk.FreeSpace

}

catch {
function Get-DriveKey {
    param([string]$Drive)

    if ([string]::IsNullOrWhiteSpace($Drive)) { return $null }
    return $Drive.Trim().TrimEnd(':').ToUpperInvariant()
}

function Get-DriveLogFile {
    param([string]$Drive)

    $key = Get-DriveKey $Drive
    if (-not $key -or -not $script:LogBaseName) { return $null }
    if (-not $script:DriveLogFiles.ContainsKey($key)) {
        $name = "{0}_{1}.log" -f $script:LogBaseName, $key
        $script:DriveLogFiles[$key] = Join-Path $LogDir $name
    }
    return $script:DriveLogFiles[$key]
}

function Get-DriveLogState {
    param([string]$Drive)

    $key = Get-DriveKey $Drive
    if (-not $key) { return $null }
    if (-not $script:DriveLogStates.ContainsKey($key)) {
        $script:DriveLogStates[$key] = [PSCustomObject]@{
            Position = 0L
            Buffer   = ""
        }
    }
    return $script:DriveLogStates[$key]
}

function Read-NewLogLines {
    param([string]$Drive)

    $logPath = Get-DriveLogFile $Drive
    if (-not $logPath -or -not (Test-Path -LiteralPath $logPath)) { return @() }

    $state = Get-DriveLogState $Drive
    if (-not $state) { return @() }

    $fs = $null
    $sr = $null
    try {
        $fs = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($state.Position -gt $fs.Length) {
            $state.Position = 0L
        }
        [void]$fs.Seek($state.Position, [System.IO.SeekOrigin]::Begin)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::Default, $true)
        $text = $sr.ReadToEnd()
        $state.Position = $fs.Position
    }
    finally {
        if ($sr) { $sr.Dispose() }
        if ($fs) { $fs.Dispose() }
    }

    if ([string]::IsNullOrEmpty($text)) { return @() }

    $text = $state.Buffer + $text
    $lines = $text -split "`r?`n"
    if (-not ($text.EndsWith("`n") -or $text.EndsWith("`r"))) {
        if ($lines.Count -gt 0) {
            $state.Buffer = $lines[-1]
            if ($lines.Count -gt 1) {
                return $lines[0..($lines.Count - 2)]
            }
        }
        return @()
    }

    $state.Buffer = ""
    return $lines
}

function Get-Win32ErrorMessage {
    param([int]$Code)

    try {
        return ([ComponentModel.Win32Exception]$Code).Message
    }
    catch {
        return $null
    }
}

function Get-RobocopyErrorFromLines {
    param([string[]]$Lines)

    if (-not $Lines -or $Lines.Count -eq 0) { return $null }

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if (-not $line) { continue }
        $line = $line.Trim()
        if ($line -match '^(?:\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s+)?ERROR\s+(\d+)\s+\((0x[0-9A-Fa-f]+)\)\s+(.*)$') {
            $code = [int]$matches[1]
            $action = $matches[3].Trim()
            $detail = $null
            if ($i + 1 -lt $Lines.Count) {
                $nextLine = $Lines[$i + 1]
                if ($nextLine) {
                    $nextLine = $nextLine.Trim()
                    if ($nextLine -and ($nextLine -notmatch '^ERROR')) {
                        $detail = $nextLine
                    }
                }
            }
            return [PSCustomObject]@{
                Win32Code    = $code
                Win32Message = (Get-Win32ErrorMessage -Code $code)
                Action       = $action
                Detail       = $detail
                Raw          = $line
            }
        }
        if ($line -match '^(?:\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s+)?ERROR:\s*(.+)$') {
            return [PSCustomObject]@{
                Win32Code    = $null
                Win32Message = $null
                Action       = $matches[1].Trim()
                Detail       = $null
                Raw          = $line
            }
        }
    }

    return $null
}

function Format-RobocopyErrorMessage {
    param([pscustomobject]$ErrorInfo)

    if (-not $ErrorInfo) { return "" }

    $parts = @()
    if ($ErrorInfo.Action) { $parts += $ErrorInfo.Action }
    if ($ErrorInfo.Win32Code) {
        $winMsg = if ($ErrorInfo.Win32Message) { $ErrorInfo.Win32Message } else { "Win32 error" }
        $parts += ("Win32={0} ({1})" -f $ErrorInfo.Win32Code, $winMsg)
    }
    if ($ErrorInfo.Detail) { $parts += $ErrorInfo.Detail }

    if ($parts.Count -eq 0) { return $ErrorInfo.Raw }
    return ($parts -join " | ")
}

function Get-RobocopyExitMessage {
    param([int]$Code)

    switch ($Code) {
        0 { return "No files copied. Source and destination are already in sync." }
        1 { return "Files copied successfully." }
        2 { return "Extra files or directories detected at destination." }
        3 { return "Files copied and extra files detected at destination." }
        4 { return "Mismatched files detected." }
        5 { return "Files copied and mismatched files detected." }
        6 { return "Extra files and mismatched files detected." }
        7 { return "Files copied, extra files and mismatched files detected." }
        default { return "Copy failed. See robocopy log for details." }
    }
}

function Get-CheckExitMessage {
    param([int]$Code)

    switch ($Code) {
        0 { return "OK." }
        1 { return "Error while checking destination or source." }
        2 { return "Mismatch: size or hash differences found." }
        3 { return "Mismatch: extra files exist on destination." }
        4 { return "Mismatch: missing files (parent folders empty)." }
        5 { return "Mismatch: missing files (parent folders have files)." }
        default { return "Unknown check result." }
    }
}

function Get-SortExitMessage {
    param([int]$Code)

    switch ($Code) {
        0 { return "Already sorted." }
        1 { return "Check failed (NG)." }
        2 { return "Sorted and applied changes." }
        3 { return "Cancelled by user." }
        4 { return "Sort error." }
        default { return "Unknown sort result." }
    }
}


# ================== HÀM GHI LOG ==================
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [string]$Drive
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
    if ($Drive) {
        $driveLog = Get-DriveLogFile -Drive $Drive
        if ($driveLog) {
            Add-Content -Path $driveLog -Value $line -Encoding utf8
        }
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

# Chọn binary PowerShell: ưu tiên pwsh 7+ nếu có, fallback powershell.exe
function Get-PreferredShellExe {
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwshCmd -and $pwshCmd.Source) {
        try { if ($pwshCmd.Version.Major -ge 7) { return $pwshCmd.Source } }
        catch { return $pwshCmd.Source }
    }
    return "powershell.exe"
}
$script:ShellExe = Get-PreferredShellExe

# Bảo đảm đường dẫn khi đưa vào cmdline không làm thoát dấu nháy do backslash cuối
function Quote-PathArg {
    param([string]$Path)

    $normalized = $Path.Trim('"')
    if ($normalized.EndsWith('\')) {
        # Nhân đôi backslash cuối để không nuốt dấu nháy kết thúc
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

    Write-Log ("Thử remount ổ {0}..." -f $DriveLetter) "WARN" -Drive $DriveLetter
    try {
        & $script:ShellExe -NoProfile -ExecutionPolicy Bypass -File $RemountScriptPath -Mode Remount -Drive $DriveLetter -CachePath $RemountCachePath -WaitSec $WaitSec
        $code = $LASTEXITCODE
    }
    catch {
        Write-Log ("Lỗi khi chạy Remount-Usb cho ổ {0}: {1}" -f $DriveLetter, $_) "ERROR" -Drive $DriveLetter
        return $false
    }

    if ($code -eq 0 -and (Wait-DriveReady $DriveLetter $WaitSec)) {
        Write-Log ("Remount ổ {0} thành công." -f $DriveLetter) -Drive $DriveLetter
        return $true
    }

    Write-Log ("Remount ổ {0} thất bại (ExitCode={1})." -f $DriveLetter, $code) "WARN" -Drive $DriveLetter
    return $false
}

function Get-BytesMd5 {
    param(
        [ValidateNotNull()]
        [byte[]]$Bytes
    )

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hashBytes = $md5.ComputeHash($Bytes)
    }
    finally {
        $md5.Dispose()
    }

    return ([System.BitConverter]::ToString($hashBytes)).Replace("-", "")
}

function Test-DriveWriteSmallFile {
    param(
        [ValidateNotNullOrEmpty()]
        [string]$DriveLetter,
        [ValidateRange(1024, 1048576)]
        [int]$MinBytes = 4096,
        [ValidateRange(1024, 1048576)]
        [int]$MaxBytes = 16384
    )

    $result = [PSCustomObject]@{
        Success   = $false
        Message   = ""
        SizeBytes = 0
    }

    if ($MinBytes -gt $MaxBytes) {
        $result.Message = "MinBytes > MaxBytes."
        return $result
    }

    $root = ($DriveLetter.TrimEnd(':') + ":\\")
    if (-not (Test-Path -LiteralPath $root)) {
        $result.Message = "Drive not ready."
        return $result
    }

    $size = Get-Random -Minimum $MinBytes -Maximum ($MaxBytes + 1)
    $bytes = New-Object byte[] $size
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }

    $hash1 = Get-BytesMd5 -Bytes $bytes
    $tmpName = ".__copyusb_write_test_{0}.tmp" -f ([guid]::NewGuid().ToString("N"))
    $tmpPath = Join-Path $root $tmpName

    try {
        $fs = [System.IO.File]::Open($tmpPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $fs.Write($bytes, 0, $bytes.Length)
            try { $fs.Flush($true) } catch { $fs.Flush() }
        }
        finally {
            $fs.Dispose()
        }

        $readBytes = [System.IO.File]::ReadAllBytes($tmpPath)
        if ($readBytes.Length -ne $bytes.Length) {
            $result.Message = "Read size mismatch."
            return $result
        }

        $hash2 = Get-BytesMd5 -Bytes $readBytes
        if ($hash1 -ne $hash2) {
            $result.Message = "Checksum mismatch."
            return $result
        }

        $result.Success = $true
        $result.SizeBytes = $size
        return $result
    }
    catch {
        $result.Message = $_.Exception.Message
        return $result
    }
    finally {
        if ($tmpPath -and (Test-Path -LiteralPath $tmpPath)) {
            try { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

function Get-DriveFreeBytes {
    param(
        [ValidateNotNullOrEmpty()]
        [string]$DriveLetter
    )

    $name = $DriveLetter.Trim().TrimEnd(':')
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    try {
        $drive = Get-PSDrive -Name $name -ErrorAction Stop
        return [int64]$drive.Free
    }
    catch {
        return $null
    }
}

function Reset-CopySpeedState {
    param(
        [ValidateNotNullOrEmpty()]
        [string]$DriveLetter
    )

    $key = Get-DriveKey $DriveLetter
    if (-not $key) { return }
    $script:CopySpeedStates[$key] = [PSCustomObject]@{
        LastFreeBytes = $null
        LastChange    = Get-Date
        NoProgress    = $false
    }
}

function Test-CopyNoProgress {
    param(
        [ValidateNotNullOrEmpty()]
        [string]$DriveLetter,
        [ValidateRange(10, 600)]
        [int]$NoProgressSec = $script:CopyNoProgressSec,
        [ValidateRange(1024, 1048576)]
        [long]$MinDeltaBytes = $script:CopyNoProgressDeltaBytes
    )

    $key = Get-DriveKey $DriveLetter
    if (-not $key) { return $null }

    if (-not $script:CopySpeedStates.ContainsKey($key)) {
        Reset-CopySpeedState -DriveLetter $DriveLetter
    }

    $state = $script:CopySpeedStates[$key]
    if ($state.NoProgress) { return $null }

    $freeBytes = Get-DriveFreeBytes -DriveLetter $DriveLetter
    if ($null -eq $freeBytes) { return $null }

    if ($null -eq $state.LastFreeBytes) {
        $state.LastFreeBytes = $freeBytes
        $state.LastChange = Get-Date
        return $null
    }

    $delta = $state.LastFreeBytes - $freeBytes
    if ([Math]::Abs($delta) -ge $MinDeltaBytes) {
        $state.LastFreeBytes = $freeBytes
        $state.LastChange = Get-Date
        return $null
    }

    $elapsed = (Get-Date) - $state.LastChange
    if ($elapsed.TotalSeconds -ge $NoProgressSec) {
        $state.NoProgress = $true
        return [PSCustomObject]@{
            NoProgressSec = [int][Math]::Floor($elapsed.TotalSeconds)
            FreeBytes     = $freeBytes
        }
    }

    return $null
}

function Get-FileHashHex {
    param(
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [ValidateNotNullOrEmpty()]
        [string]$Algorithm,
        [string]$Drive
    )

    $algoName = $Algorithm.ToUpperInvariant()
    if ($algoName -ne "MD5" -and $algoName -ne "SHA256") {
        $algoName = "MD5"
        if ($Drive) {
            Write-Log ("[RESUME] HashAlgorithm {0} not supported, fallback to MD5." -f $Algorithm) "WARN" -Drive $Drive
        } else {
            Write-Log ("[RESUME] HashAlgorithm {0} not supported, fallback to MD5." -f $Algorithm) "WARN"
        }
    }

    $algo = if ($algoName -eq "SHA256") { [System.Security.Cryptography.SHA256]::Create() } else { [System.Security.Cryptography.MD5]::Create() }
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $hashBytes = $algo.ComputeHash($fs)
        }
        finally {
            $fs.Dispose()
        }
    }
    finally {
        $algo.Dispose()
    }

    return ([System.BitConverter]::ToString($hashBytes)).Replace("-", "")
}

function Get-Mp3ListSimple {
    param(
        [ValidateNotNullOrEmpty()]
        [string]$Root
    )

    if (-not (Test-Path -LiteralPath $Root)) { return @() }

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

function Invoke-PreFormatResumeCheck {
    param(
        [ValidateNotNullOrEmpty()]
        [string]$DriveLetter,
        [ValidateNotNullOrEmpty()]
        [string]$DestPath
    )

    $result = [PSCustomObject]@{
        Resume       = $false
        ExitCode     = 0
        MissingBytes = 0
        MissingCount = 0
        LastRelPath  = ""
        LastDestPath = ""
        HashMatch    = $true
        ErrorMessage = ""
    }

    if (-not (Test-Path -LiteralPath $DestPath)) {
        $result.ErrorMessage = "Dest path not found."
        return $result
    }
    if (-not (Test-Path -LiteralPath $CheckScriptPath)) {
        $result.ErrorMessage = "Check script not found."
        return $result
    }

    $driveLog = Get-DriveLogFile -Drive $DriveLetter
    $checkScriptFull = [System.IO.Path]::GetFullPath($CheckScriptPath)
    $checkArgs = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $checkScriptFull,
        "-SourceRoot", $SourceRoot,
        "-DestDrives", $DriveLetter,
        "-NoConfirm",
        "-NoPause",
        "-Hash", # EnableHash,
        "-LogFile", $driveLog,
        "-HashLastN", 0,
        "-HashAlgorithm", $HashAlgorithm
    )
    $null = & $script:ShellExe @checkArgs
    $result.ExitCode = $LASTEXITCODE

    if ($result.ExitCode -ne 4 -and $result.ExitCode -ne 5) {
        return $result
    }

    $result.Resume = $true
    $srcList = Get-Mp3ListSimple -Root $SourceRoot
    $dstList = Get-Mp3ListSimple -Root $DestPath
    if ($srcList.Count -eq 0 -or $dstList.Count -eq 0) {
        $result.ErrorMessage = "Source or dest mp3 list empty."
        $result.Resume = $false
        return $result
    }

    $dstMap = @{}
    foreach ($d in $dstList) {
        $dstMap[$d.RelPath] = $d
    }

    $missingBytes = 0L
    $missingCount = 0
    $common = @()
    foreach ($s in $srcList) {
        if ($dstMap.ContainsKey($s.RelPath)) {
            $common += $s
        } else {
            $missingCount++
            $missingBytes += [int64]$s.Length
        }
    }

    $result.MissingBytes = $missingBytes
    $result.MissingCount = $missingCount

    if ($common.Count -eq 0) {
        $result.ErrorMessage = "No common mp3 files."
        $result.Resume = $false
        return $result
    }

    $lastCommon = $common | Sort-Object RelPath | Select-Object -Last 1
    $dstFile = $dstMap[$lastCommon.RelPath]
    $result.LastRelPath = $lastCommon.RelPath
    $result.LastDestPath = $dstFile.FullName

    $srcHash = Get-FileHashHex -Path $lastCommon.FullName -Algorithm $HashAlgorithm -Drive $DriveLetter
    $dstHash = Get-FileHashHex -Path $dstFile.FullName -Algorithm $HashAlgorithm -Drive $DriveLetter
    $result.HashMatch = ($srcHash -eq $dstHash)

    return $result
}

# ================== KHỞI TẠO LOG ==================
if ($script:LogDirIsEmpty) {
    Write-Host "Thư mục log rỗng. Vui lòng chỉ định -LogDir hợp lệ." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}
$logName = "copycheckeject_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss")
$script:LogFile = Join-Path $LogDir $logName
$script:LogFile = [System.IO.Path]::GetFullPath($script:LogFile)
$script:LogBaseName = [System.IO.Path]::GetFileNameWithoutExtension($script:LogFile)

Write-Log "===== BẮT ĐẦU QUY TRÌNH COPY - CHECK - EJECT ====="
# ================== KIỂM TRA THAM SỐ CƠ BẢN ==================

if (-not (Test-Path $SourceRoot)) {
    Write-Log "Thư mục nguồn không tồn tại: $SourceRoot" "ERROR"
    Write-Host ""
    Write-Host "Vui lòng kiểm tra lại tham số -SourceRoot." -ForegroundColor Red
    exit 1
}
# Chuẩn hóa SourceRoot: bỏ nháy thừa, chuyển thành full path
$SourceRoot = $SourceRoot.Trim('"')
$SourceRoot = (Resolve-Path $SourceRoot).ProviderPath

# Validate script CHECK
if ($script:CheckPathIsEmpty) {
    Write-Log "CheckScriptPath rỗng. Vui lòng chỉ định đường dẫn hợp lệ." "ERROR"
    exit 1
}

if (-not (Test-Path $CheckScriptPath)) {
    Write-Log "Script CHECK không tồn tại: $CheckScriptPath" "ERROR"
    exit 1
}

# Validate script SORT
if ($CheckAndSort) {
    if ($script:SortScriptIsEmpty) {
        Write-Log "SortScriptPath rỗng. Vui lòng chỉ định đường dẫn hợp lệ." "ERROR"
        exit 1
    }
    if (-not (Test-Path $SortScriptPath)) {
        Write-Log "Script SORT không tồn tại: $SortScriptPath" "ERROR"
        exit 1
    }
} else {
    Write-Log "Bỏ qua bước SORT (CheckAndSort = false)." "WARN"
}

# X? ly SkipEject va validate script EJECT
if (-not $script:SkipEjectEffective) {
    if ($script:EjectPathIsEmpty) {
        Write-Log "EjectScriptPath rỗng -> bỏ qua bước EJECT." "WARN"
        $script:SkipEjectEffective = $true
    } elseif (-not (Test-Path $EjectScriptPath)) {
        Write-Log "Script EJECT không tồn tại: $EjectScriptPath" "ERROR"
        exit 1
    }
} elseif ($script:EjectPathIsEmpty) {
    Write-Log "EjectScriptPath rỗng -> bỏ qua bước EJECT." "WARN"
} else {
    Write-Log "Bỏ qua bước EJECT (SkipEject được bật)." "WARN"
}

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
Write-Host "SortScriptPath  : $SortScriptPath"
Write-Host "CheckAndSort    : $CheckAndSort"
Write-Host "EjectScriptPath : $EjectScriptPath"
Write-Host "RemountScript   : $RemountScriptPath"
Write-Host "RemountCache    : $RemountCachePath"
Write-Host "LogFile         : $script:LogFile"
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
# Nếu không có dữ liệu nguồn thì dừng luôn, tránh chạy format/copy không cần thiết
if ($sourceSize -le 0) {
    Write-Log "Source không có dữ liệu (0 byte). Dừng quy trình, không thực hiện copy/check/eject." "WARN"
    exit 0
}

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
        $rootPath = "$upper\\"
        if (-not (Test-Path -LiteralPath $rootPath)) {
            Write-Log "? ${upper}: không truy cập được (Test-Path thất bại). Bỏ qua." "WARN"
            continue
        }
        if (-not $disk.Size -or $disk.Size -le 0) {
            Write-Log "Ổ $upper có Size=0 (có thể không có thẻ nhớ). Bỏ qua." "WARN" -Drive $upper
            continue
        }
        if ($disk.Size -lt $sourceSize) {
            Write-Log ("Ổ {0} có Size {1:N2}GB nhỏ hơn dung lượng source {2:N2}GB. Bỏ qua." -f $upper, ($disk.Size/1GB), ($sourceSize/1GB)) "WARN" -Drive $upper
            continue
        }
        Write-Log ("Ổ {0} (USB) Size={1:N2}GB, Free={2:N2}GB" -f `
                $upper, ($disk.Size / 1GB), ($disk.FreeSpace / 1GB))
        $ValidTargets += $upper
    }
    else {
        Write-Log "Ổ $upper KHÔNG phải USB (hoặc không tìm thấy). Bỏ qua." "WARN" -Drive $upper
    }
}
if ($ValidTargets.Count -eq 0) {
    Write-Log "Không có ổ USB hợp lệ để xử lý." "ERROR"
    exit 1
}
# ================== CAPTURE THONG TIN REMOUNT ==================
if ($script:RemountScriptIsEmpty -or $script:RemountCacheIsEmpty) {
    if ($script:RemountScriptIsEmpty) {
        Write-Log "RemountScriptPath rỗng -> không thể capture/remount khi có lỗi." "WARN"
    }
    if ($script:RemountCacheIsEmpty) {
        Write-Log "RemountCachePath rỗng -> không thể lưu cache remount, bỏ qua remount." "WARN"
    }
} elseif (Test-Path $RemountScriptPath) {
    Write-Log "Capture thông tin remount cho các ổ USB hợp lệ..."
    foreach ($drv in $ValidTargets) {
        try {
            & $script:ShellExe -NoProfile -ExecutionPolicy Bypass -File $RemountScriptPath -Mode Capture -Drive $drv -CachePath $RemountCachePath
            $capCode = $LASTEXITCODE
            if ($capCode -eq 0) {
                Write-Log ("Capture remount OK cho ổ {0}, cache: {1}" -f $drv, $RemountCachePath) -Drive $drv
            } else {
                Write-Log ("Capture remount cho ổ {0} thất bại (ExitCode={1}). Tiếp tục mà không có cache remount cho ổ này." -f $drv, $capCode) "WARN" -Drive $drv
            }
        }
        catch {
            Write-Log ("Lỗi khi capture remount ở {0}: {1}" -f $drv, $_) "WARN" -Drive $drv
        }
    }
} else {
    Write-Log "Không tìm thấy Remount-Usb.ps1, bỏ qua bước capture remount." "WARN"
}

# ================== CẢNH BÁO RIÊNG CHO Ổ USB >= 16GB ==================
$LargeUsb = @($ValidTargets | Where-Object {
    $usbMap[$_].Size -ge (16GB)
})

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
        $ValidTargets = @($ValidTargets | Where-Object { $LargeUsb -notcontains $_ })
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
    $resumeCopy = $false
    $resumeMissingBytes = 0L

    Write-Log ("--- ĐÁNH GIÁ Ổ {0} ---" -f $drv) -Drive $drv
    Write-Log ("Size={0:N2}GB, Free={1:N2}GB, Used={2:N2}MB ({3:P1})" -f `
        ($totalSize / 1GB), ($freeSpace / 1GB), $usedMB, $usedPct)

    # *** BƯỚC 0: check capacity tổng có đủ chứa source không ***
    if ($totalSize -ge $sourceSize) {

        # BƯỚC 1: quyết định xử lý dữ liệu hiện có
        $skipCleanup = $false
        if (-not $AutoYes -and $freeSpace -ge $sourceSize -and $usedMB -ge 20) {
            Write-Host ""
            Write-Host ("Ổ {0} đang còn trống {1:N2}GB, đủ để chứa source ~{2:N2}GB." -f $drv, ($freeSpace / 1GB), ($sourceSize / 1GB)) -ForegroundColor Yellow
            $ansKeep = Read-Host "GIỮ NGUYÊN dữ liệu, KHÔNG xóa/format? (Y = giữ, giá trị khác = vẫn xóa/format)"
            if ($ansKeep -and $ansKeep.ToUpper() -eq "Y") {
                $skipCleanup = $true
                Write-Log ("Người dùng chọn giữ nguyên dữ liệu trên ổ {0} (không xóa/format vì freeSpace đủ)." -f $drv) "WARN" -Drive $drv
            }
        }

        if ($usedMB -lt 20) {
            Write-Log "Dữ liệu hiện tại trên ổ $drv < 20MB → giữ nguyên, chỉ copy thêm." -Drive $drv
            # Không đụng vào dữ liệu; freeSpace vẫn giữ giá trị hiện tại
        }
        else {
            Write-Log ("CẢNH BÁO: ổ {0} đang có dữ liệu {1:N2}MB." -f $drv, $usedMB) "WARN" -Drive $drv

            $resumeCopy = $false
            $resumeMissingBytes = 0L
            if (-not $skipCleanup -and $usedPct -ge 0.2) {
                $destPath = Join-Path $drv (Split-Path $SourceRoot -Leaf)
                Write-Log ("[RESUME] Pre-format check on {0}..." -f $drv) "WARN" -Drive $drv
                $resumeInfo = Invoke-PreFormatResumeCheck -DriveLetter $drv -DestPath $destPath
                if (($resumeInfo.ExitCode -eq 4 -or $resumeInfo.ExitCode -eq 5) -and $resumeInfo.Resume) {
                    Write-Log ("[RESUME] ExitCode=4 or 5. Missing: {0} files, ~{1:N2}MB." -f $resumeInfo.MissingCount, ($resumeInfo.MissingBytes / 1MB)) "WARN" -Drive $drv
                    if (-not $resumeInfo.HashMatch) {
                        Write-Log ("[RESUME] Last file hash mismatch -> delete dest file: {0}" -f $resumeInfo.LastRelPath) "WARN" -Drive $drv
                        try {
                            Remove-Item -LiteralPath $resumeInfo.LastDestPath -Force -ErrorAction Stop
                        }
                        catch {
                            Write-Log ("[RESUME] Failed to delete last file: {0}" -f $_.Exception.Message) "ERROR" -Drive $drv
                        }
                    } else {
                        Write-Log "[RESUME] Last file hash match -> resume copy without format." -Drive $drv
                    }
                    $resumeCopy = $true
                    $resumeMissingBytes = [int64]$resumeInfo.MissingBytes
                    $skipCleanup = $true
                }
            }


            if ($skipCleanup) {
                Write-Log ("Bỏ qua xóa/format ổ {0} theo lựa chọn của người dùng." -f $drv) "WARN" -Drive $drv
            }
            elseif ($usedPct -lt 0.2) {
                # OPTION A: xóa file
                Write-Log ("Áp dụng OPTION A cho {0}: Xóa toàn bộ file (Used<{1:P0} dung lượng)." -f $drv, 0.2) -Drive $drv
                try {
                    Get-ChildItem -Path ($drv + "\") -Force | Remove-Item -Recurse -Force -ErrorAction Stop
                    Write-Log "Đã xóa toàn bộ dữ liệu trên ổ $drv." -Drive $drv
                    # tùy chọn: chờ ổ ổn định lại
                    if (-not (Wait-DriveReady $drv 15)) {
                        Write-Log "Sau khi xóa dữ liệu, ổ $drv có vẻ không ổn định. BỎ QUA ổ này." "ERROR" -Drive $drv
                        continue
                    }
                    # Reload thông tin disk
                    $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drv)
                    $totalSize = [double]$disk.Size
                    $freeSpace = [double]$disk.FreeSpace
                }
                catch {
                    Write-Log "Lỗi khi xóa dữ liệu trên ổ ${drv}: $_" "ERROR" -Drive $drv
                    continue
                }
            }
            else {
                $sizeMB = [double]($totalSize / 1MB)
                $useFat16 = ($sizeMB -lt 4000)
                $fsType = if ($useFat16) { "FAT" } else { "FAT32" }
                $clusterSize = if ($useFat16) { 16384 } else { 32768 }
                if ($useFat16) {
                    $required = [Math]::Ceiling([double]$totalSize / 65525)
                    if ($required -gt $clusterSize) {
                        $allowed = @(2048, 4096, 8192, 16384, 32768, 65536)
                        $newSize = ($allowed | Where-Object { $_ -ge $required } | Select-Object -First 1)
                        if (-not $newSize) { $newSize = $allowed[-1] }
                        if ($newSize -ne $clusterSize) {
                            Write-Log ("FAT16 cluster 16KB invalid for size, fallback to {0}KB." -f ($newSize / 1KB)) "WARN" -Drive $drv
                            $clusterSize = $newSize
                        }
                    }
                }

                # Windows th??ng khong cho FAT32 > 32GB
                if ((-not $useFat16) -and ($totalSize -gt 32GB)) {
                    Write-Log ("? {0} > 32GB, th??ng khong format FAT32 ???c tren Windows. B? QUA ? nay." -f $drv) "ERROR" -Drive $drv
                    continue
                }

                try {
                    $letter = $drv.TrimEnd(':')
                    $fsLabel = if ($useFat16) { "FAT16" } else { $fsType }
                    Write-Log ("Dang format {0} (cluster {1}KB) o {2}..." -f $fsLabel, ($clusterSize / 1KB), $drv) "WARN" -Drive $drv
                    Format-Volume -DriveLetter $letter -FileSystem $fsType -AllocationUnitSize $clusterSize -NewFileSystemLabel "USB_$letter" -Confirm:$false -Force -ErrorAction Stop
                    Write-Log ("Da quick format {0} (cluster {1}KB) o {2}." -f $fsLabel, ($clusterSize / 1KB), $drv) -Drive $drv

                    # Cho ? mount l?i
                    if (-not (Wait-DriveReady $drv 30)) {
                        Write-Log "Sau khi format, ? $drv khong ready trong 30s. B? QUA ? nay." "ERROR" -Drive $drv
                        continue
                    }

                    $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drv)
                    $totalSize = [double]$disk.Size
                    $freeSpace = [double]$disk.FreeSpace
                }
                catch {
                    Write-Log "Lỗi khi format ổ ${drv}: $_" "ERROR" -Drive $drv
                    continue
                }
                }
            }
        }

        # BƯỚC 2: check freeSpace sau xử lý
        $requiredBytes = if ($resumeCopy) { $resumeMissingBytes } else { $sourceSize }
        if ($freeSpace -lt $requiredBytes) {
            $needLabel = if ($resumeCopy) { "Missing" } else { "Source" }
            Write-Log ("? {0} KHONG du dung luong trong sau xu ly. Free={1:N2}GB, {2}~{3:N2}GB" -f $drv, ($freeSpace / 1GB), $needLabel, ($requiredBytes / 1GB)) "ERROR"
            continue
        }

        Write-Log ("Ổ {0} đủ điều kiện để copy." -f $drv) -Drive $drv
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

    $driveKey = Get-DriveKey $DriveLetter
    if ($driveKey) {
        if ($script:StartCopyErrors.ContainsKey($driveKey)) { $script:StartCopyErrors.Remove($driveKey) | Out-Null }
        if ($script:CopyAbortReasons.ContainsKey($driveKey)) { $script:CopyAbortReasons.Remove($driveKey) | Out-Null }
    }

    if (-not (Wait-DriveReady $DriveLetter 30)) {
        Write-Log ("Ổ {0} KHÔNG ready trước khi copy." -f $DriveLetter) "ERROR" -Drive $DriveLetter
        if (Try-RemountDrive -DriveLetter $DriveLetter -WaitSec 30) {
            Write-Log ("Ổ {0} đã remount, tiếp tục copy." -f $DriveLetter) "WARN" -Drive $DriveLetter
        } else {
            return $null
        }
    }

    Write-Log ("[WRITE-TEST] {0}: test write small file before copy..." -f $DriveLetter) -Drive $DriveLetter
    $writeTest = Test-DriveWriteSmallFile -DriveLetter $DriveLetter -MinBytes $script:WriteTestMinBytes -MaxBytes $script:WriteTestMaxBytes
    if (-not $writeTest.Success) {
        $msg = if ($writeTest.Message) { $writeTest.Message } else { "Write test failed." }
        Write-Log ("[WRITE-TEST] {0}: FAIL -> FLAG SD BAD -> STOP. {1}" -f $DriveLetter, $msg) "ERROR" -Drive $DriveLetter
        if ($driveKey) {
            $script:StartCopyErrors[$driveKey] = [PSCustomObject]@{
                Stage   = "WRITE_TEST"
                Code    = 901
                Message = ("FLAG SD BAD (pre-copy). {0}" -f $msg)
            }
        }
        return $null
    }
    Write-Log ("[WRITE-TEST] {0}: OK ({1} KB)." -f $DriveLetter, ([Math]::Round($writeTest.SizeBytes / 1KB, 1))) -Drive $DriveLetter

    $destPath = Join-Path $DriveLetter (Split-Path $SourceRoot -Leaf)
    try {
        if (-not (Test-Path $destPath)) {
            New-Item -Path $destPath -ItemType Directory -Force | Out-Null
        }
    }
    catch {
        Write-Log "Lỗi khi tạo thư mục đích $destPath trên ổ ${DriveLetter}: $_" "ERROR" -Drive $DriveLetter
        return $null
    }

    Reset-CopySpeedState -DriveLetter $DriveLetter

    $srcArg = Quote-PathArg $SourceRoot
    $dstArg = Quote-PathArg $destPath
    $modeSwitch = if ($UseMirror) { "/MIR" } else { "/E" }
    $driveLog = Get-DriveLogFile -Drive $DriveLetter
    if (-not $driveLog) { $driveLog = $script:LogFile }
    $logArg = "/LOG+:" + (Quote-PathArg $driveLog)

    $params = @(
        $srcArg,
        $dstArg,
        $modeSwitch,
        "/R:2",
        "/W:2",
        $logArg,
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
        Write-Log ("Copy ổ {0} chạy MIRROR (do quick check ExitCode=3)." -f $DriveLetter) "WARN" -Drive $DriveLetter
    }

    Write-Log ("Chạy robocopy tới {0}: robocopy {1}" -f $DriveLetter, ($params -join ' ')) -Drive $DriveLetter
    $p = Start-Process -FilePath "robocopy.exe" -ArgumentList ($params -join ' ') -PassThru -WindowStyle Hidden
    return [PSCustomObject]@{
        Drive     = $DriveLetter
        Process   = $p
        UseMirror = $UseMirror
        LogPath   = $driveLog
    }
}

function Invoke-PostCopyFlow {
    param(
        [string]$DriveLetter
    )

    $result = [PSCustomObject]@{
        Drive   = $DriveLetter
        Success = $true
        Stage   = ""
        Code    = 0
        Message = ""
    }

    if (-not (Test-Path $CheckScriptPath)) {
        Write-Log ("Không tìm thấy script CHECK: {0}. Dừng flow ở {1}." -f $CheckScriptPath, $DriveLetter) "ERROR" -Drive $DriveLetter
        $result.Success = $false
        $result.Stage = "CHECK"
        $result.Code = 1
        $result.Message = "Check script not found."
        return $result
    }

    Write-Log ("BẮT ĐẦU BƯỚC CHECK cho ổ {0}..." -f $DriveLetter) -Drive $DriveLetter
    $driveLog = Get-DriveLogFile -Drive $DriveLetter
    $checkScriptFull = [System.IO.Path]::GetFullPath($CheckScriptPath)
    $checkArgs = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $checkScriptFull,
        "-SourceRoot", $SourceRoot,
        "-DestDrives", $DriveLetter,
        "-NoConfirm",
        "-NoPause",
        "-LogFile", $driveLog,
        "-HashLastN", $HashLastN,
        "-HashAlgorithm", $HashAlgorithm
    )
    if ($EnableHash) { $checkArgs += "-Hash" }
    Write-Log ("CMD CHECK ({0}): {1} {2}" -f $DriveLetter, $script:ShellExe, ($checkArgs -join " ")) -Drive $DriveLetter
    $null = & $script:ShellExe @checkArgs
    $checkCode = $LASTEXITCODE
    $checkMsg = Get-CheckExitMessage -Code $checkCode
    if ($checkCode -ne 0) {
        Write-Log ("CHECK detail: {0}" -f $checkMsg) "ERROR" -Drive $DriveLetter
        Write-Log ("BƯỚC CHECK lỗi cho ổ {0} (ExitCode={1}). Dừng flow ở ổ này." -f $DriveLetter, $checkCode) "ERROR" -Drive $DriveLetter
        $result.Success = $false
        $result.Stage = "CHECK"
        $result.Code = $checkCode
        $result.Message = $checkMsg
        return $result
    }
    Write-Log ("BƯỚC CHECK hoàn tất cho ổ {0}." -f $DriveLetter) -Drive $DriveLetter

    if ($CheckAndSort) {
        if (-not (Test-Path $SortScriptPath)) {
            Write-Log ("Không tìm thấy script SORT: {0}. Dừng flow ở {1}." -f $SortScriptPath, $DriveLetter) "ERROR" -Drive $DriveLetter
            $result.Success = $false
            $result.Stage = "SORT"
            $result.Code = 1
            $result.Message = "Sort script not found."
            return $result
        }
        Write-Log ("BẮT ĐẦU BƯỚC SORT cho ổ {0}..." -f $DriveLetter) -Drive $DriveLetter
        $sortScriptFull = [System.IO.Path]::GetFullPath($SortScriptPath)
        $deviceArg = $DriveLetter.ToLower()
        $sortArgs = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", $sortScriptFull,
            "-Device", $deviceArg,
            "-Mode", "CheckAndSort",
            "-Force"
        )
        Write-Log ("CMD SORT ({0}): {1} {2}" -f $DriveLetter, $script:ShellExe, ($sortArgs -join " ")) -Drive $DriveLetter
        $null = & $script:ShellExe @sortArgs
        $sortCode = $LASTEXITCODE
        $sortMsg = Get-SortExitMessage -Code $sortCode
        if ($sortCode -ne 0 -and $sortCode -ne 2) {
            Write-Log ("SORT detail: {0}" -f $sortMsg) "ERROR" -Drive $DriveLetter
            Write-Log ("BƯỚC SORT lỗi cho ổ {0} (ExitCode={1}). Dừng flow ở ổ này." -f $DriveLetter, $sortCode) "ERROR" -Drive $DriveLetter
            $result.Success = $false
            $result.Stage = "SORT"
            $result.Code = $sortCode
            $result.Message = $sortMsg
            return $result
        }
        Write-Log ("SORT detail: {0}" -f $sortMsg) -Drive $DriveLetter
        Write-Log ("BƯỚC SORT hoàn tất cho ổ {0}." -f $DriveLetter) -Drive $DriveLetter
    }

    if ($script:SkipEjectEffective) {
        Write-Log ("Bỏ qua bước EJECT cho ổ {0} (SkipEject)." -f $DriveLetter) "WARN" -Drive $DriveLetter
        return $result
    }
    if (-not (Test-Path $EjectScriptPath)) {
        Write-Log ("Không tìm thấy script EJECT: {0}. Bỏ qua EJECT cho ổ {1}." -f $EjectScriptPath, $DriveLetter) "WARN" -Drive $DriveLetter
        return $result
    }

    Write-Log ("BẮT ĐẦU BƯỚC EJECT cho ổ {0}..." -f $DriveLetter) -Drive $DriveLetter
    $ejectScriptFull = [System.IO.Path]::GetFullPath($EjectScriptPath)
    $drvArg = $DriveLetter.ToLower()
    $argListEject = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ejectScriptFull, $drvArg)
    Write-Log ("CMD EJECT ({0}): {1} {2}" -f $DriveLetter, $script:ShellExe, ($argListEject -join " ")) -Drive $DriveLetter
    $null = & $script:ShellExe @argListEject
    $ejectCode = $LASTEXITCODE
    if ($ejectCode -ne 0) {
        Write-Log ("BƯỚC EJECT lỗi cho ổ {0} (ExitCode={1})." -f $DriveLetter, $ejectCode) "ERROR" -Drive $DriveLetter
        $result.Success = $false
        $result.Stage = "EJECT"
        $result.Code = $ejectCode
        $result.Message = "Eject failed."
        return $result
    }
    Write-Log ("BƯỚC EJECT hoàn tất cho ổ {0}." -f $DriveLetter) -Drive $DriveLetter

    return $result
}

Write-Log "BẮT ĐẦU BƯỚC COPY (robocopy)..."

$copyResults = @{}
$flowErrors = @{}
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
        $startErr = $null
        $driveKey = Get-DriveKey $drv
        if ($driveKey -and $script:StartCopyErrors.ContainsKey($driveKey)) {
            $startErr = $script:StartCopyErrors[$driveKey]
        }
        if ($startErr) {
            $flowErrors[$drv] = [PSCustomObject]@{
                Drive   = $drv
                Success = $false
                Stage   = $startErr.Stage
                Code    = $startErr.Code
                Message = $startErr.Message
            }
        } else {
            $flowErrors[$drv] = [PSCustomObject]@{
                Drive   = $drv
                Success = $false
                Stage   = "COPY"
                Code    = 999
                Message = "Failed to start robocopy."
            }
        }
    }
    Start-Sleep -Milliseconds 300
}

# Giam sat tien trinh copy theo o
while ((@($active)).Count -gt 0) {
    $procs = $active | Select-Object -ExpandProperty Process
    try {
        [void](Wait-Process -InputObject $procs -Any -Timeout 5 -ErrorAction SilentlyContinue)
    } catch {
        Start-Sleep -Seconds 1
    }

    foreach ($item in @($active)) {
        $drv = $item.Drive
        $driveKey = Get-DriveKey $drv
        if ($driveKey -and $script:CopyAbortReasons.ContainsKey($driveKey)) {
            continue
        }

        if (-not $script:EarlyCopyErrors.ContainsKey($drv)) {
            $newLines = Read-NewLogLines -Drive $drv
            $errInfo = Get-RobocopyErrorFromLines -Lines $newLines
            if ($errInfo) {
                $script:EarlyCopyErrors[$drv] = $errInfo
                $detail = Format-RobocopyErrorMessage -ErrorInfo $errInfo
                Write-Log ("COPY toi {0} phat hien loi robocopy, dung som. {1}" -f $drv, $detail) "ERROR" -Drive $drv
                try { Stop-Process -Id $item.Process.Id -Force -ErrorAction SilentlyContinue } catch { }
            }
        }

        if (-not $script:EarlyCopyErrors.ContainsKey($drv)) {
            $noProgress = Test-CopyNoProgress -DriveLetter $drv -NoProgressSec $script:CopyNoProgressSec -MinDeltaBytes $script:CopyNoProgressDeltaBytes
            if ($noProgress) {
                Write-Log ("[SPEED] {0}: 0 KB/s > {1}s -> pause copy, test write." -f $drv, $noProgress.NoProgressSec) "WARN" -Drive $drv
                try { Stop-Process -Id $item.Process.Id -Force -ErrorAction SilentlyContinue } catch { }
                $writeTest = Test-DriveWriteSmallFile -DriveLetter $drv -MinBytes $script:WriteTestMinBytes -MaxBytes $script:WriteTestMaxBytes
                if (-not $writeTest.Success) {
                    $msg = if ($writeTest.Message) { $writeTest.Message } else { "Write test failed." }
                    Write-Log ("[WRITE-TEST] {0}: FAIL -> FLAG SD BAD -> ABORT COPY. {1}" -f $drv, $msg) "ERROR" -Drive $drv
                    if ($driveKey) {
                        $script:CopyAbortReasons[$driveKey] = [PSCustomObject]@{
                            Flag    = "BAD"
                            Message = ("FLAG SD BAD. {0}" -f $msg)
                        }
                    }
                }
                else {
                    Write-Log ("[WRITE-TEST] {0}: OK -> FLAG SD WEAK -> ABORT COPY." -f $drv) "WARN" -Drive $drv
                    if ($driveKey) {
                        $script:CopyAbortReasons[$driveKey] = [PSCustomObject]@{
                            Flag    = "WEAK"
                            Message = ("FLAG SD WEAK. Write test OK after 0 KB/s > {0}s." -f $noProgress.NoProgressSec)
                        }
                    }
                }
            }
        }
    }

    $doneSet = $active | Where-Object { $_.Process.HasExited }
    if (-not $doneSet) { continue }

    foreach ($done in @($doneSet)) {
        $drv = $done.Drive
        $code = $done.Process.ExitCode
        $driveKey = Get-DriveKey $drv
        $abortInfo = $null
        if ($driveKey -and $script:CopyAbortReasons.ContainsKey($driveKey)) {
            $abortInfo = $script:CopyAbortReasons[$driveKey]
        }

        if ($abortInfo) {
            $copyResults[$drv] = $code
            $active = @($active | Where-Object { $_.Process.Id -ne $done.Process.Id })
            Write-Log ("COPY toi {0} BI ABORT. {1}" -f $drv, $abortInfo.Message) "ERROR" -Drive $drv
            $flowErrors[$drv] = [PSCustomObject]@{
                Drive   = $drv
                Success = $false
                Stage   = "COPY"
                Code    = 998
                Message = $abortInfo.Message
            }
            if ($driveKey -and $script:CopySpeedStates.ContainsKey($driveKey)) {
                $script:CopySpeedStates.Remove($driveKey) | Out-Null
            }
            continue
        }

        $earlyErr = $null
        if ($script:EarlyCopyErrors.ContainsKey($drv)) { $earlyErr = $script:EarlyCopyErrors[$drv] }
        $copyMsg = if ($earlyErr) { Format-RobocopyErrorMessage -ErrorInfo $earlyErr } else { Get-RobocopyExitMessage -Code $code }
        $isFailure = $false
        if ($earlyErr) { $isFailure = $true } elseif ($code -ge 8) { $isFailure = $true }
        $copyResults[$drv] = $code
        $active = @($active | Where-Object { $_.Process.Id -ne $done.Process.Id })

        if (-not $isFailure) {
            Write-Log ("COPY toi {0} HOAN TAT. ExitCode={1}. {2}" -f $drv, $code, $copyMsg) -Drive $drv
            $flowResult = Invoke-PostCopyFlow -DriveLetter $drv
            if (-not $flowResult.Success) {
                $flowErrors[$drv] = $flowResult
            }
            continue
        }

        Write-Log ("COPY toi {0} THAT BAI. ExitCode={1}. {2}" -f $drv, $code, $copyMsg) "ERROR" -Drive $drv
        if ($AutoYes) {
            Write-Log "AutoYes đang bật -> không thử lại copy cho ổ này." "ERROR" -Drive $drv
            $flowErrors[$drv] = [PSCustomObject]@{
                Drive   = $drv
                Success = $false
                Stage   = "COPY"
                Code    = $code
                Message = $copyMsg
            }
            continue
        }

        $stillThere = Test-Path ($drv + "\\")
        if (-not $stillThere) {
            Write-Log ("Ổ {0} không còn sẵn sàng (có thể bị rút). Thử remount..." -f $drv) "ERROR" -Drive $drv
            $remounted = Try-RemountDrive -DriveLetter $drv -WaitSec 30
            if ($remounted) {
                Write-Log ("Remount ổ {0} thành công, thử copy lại..." -f $drv) "WARN" -Drive $drv
                $retryProc = Start-CopyProcess -DriveLetter $drv -UseMirror ($MirrorTargets -contains $drv) -ThreadNo $threadNo
                if ($retryProc) {
                    $copyResults.Remove($drv) | Out-Null
                    $active += $retryProc
                    continue
                } else {
                    Write-Log ("Khởi động copy lại ổ {0} sau remount thất bại." -f $drv) "ERROR" -Drive $drv
                }
            }
        }

        $ans = Read-Host ("Ổ {0} gặp lỗi (ExitCode={1}). Cắm lại/Remount nếu đã rút, nhập Y để thử copy lại, phím khác = bỏ qua ổ này" -f $drv, $code)
        if ($ans -and $ans.ToUpper() -eq 'Y') {
            if (-not (Wait-DriveReady $drv 60)) {
                Write-Log ("Ổ {0} vẫn không sẵn sàng sau 60s. Bỏ qua ổ này." -f $drv) "ERROR" -Drive $drv
                $flowErrors[$drv] = [PSCustomObject]@{
                    Drive   = $drv
                    Success = $false
                    Stage   = "COPY"
                    Code    = $code
                    Message = $copyMsg
                }
                continue
            }
            Write-Log ("Thử copy lại ổ {0}..." -f $drv) -Drive $drv
            $retryProc = Start-CopyProcess -DriveLetter $drv -UseMirror ($MirrorTargets -contains $drv) -ThreadNo $threadNo
            if ($retryProc) {
                $copyResults.Remove($drv) | Out-Null
                $active += $retryProc
            } else {
                Write-Log ("Khởi động copy lại ổ {0} thất bại, giữ nguyên lỗi trước đó." -f $drv) "ERROR" -Drive $drv
                $flowErrors[$drv] = [PSCustomObject]@{
                    Drive   = $drv
                    Success = $false
                    Stage   = "COPY"
                    Code    = $code
                    Message = $copyMsg
                }
            }
        }
        else {
            Write-Log ("Người dùng chọn bỏ qua copy cho ổ {0}." -f $drv) "WARN" -Drive $drv
            $flowErrors[$drv] = [PSCustomObject]@{
                Drive   = $drv
                Success = $false
                Stage   = "COPY"
                Code    = $code
                Message = $copyMsg
            }
        }
    }
}

$overallExitCode = 0
Write-Log "Đã hoàn tất theo dõi copy và xử lý theo từng ổ."
if ($flowErrors.Count -gt 0) {
    Write-Log "Một hoặc nhiều ổ gặp lỗi trong quá trình xử lý." "ERROR"
    foreach ($k in $flowErrors.Keys) {
        $e = $flowErrors[$k]
        Write-Log (" - {0}: Lỗi {1} (ExitCode={2})" -f $k, $e.Stage, $e.Code) "ERROR"
        if ($e.Message) {
            Write-Log ("   detail: {0}" -f $e.Message) "ERROR" -Drive $k
        }
    }
    $overallExitCode = 1
} else {
    Write-Log "Tất cả các ổ đã hoàn tất đầy đủ các bước."
}

Write-Log "===== QUY TRÌNH HOÀN THÀNH ====="
Write-Host ""
Write-Host "Log file: $script:LogFile" -ForegroundColor Cyan
if ($overallExitCode -ne 0) {
	pause 
	exit $overallExitCode
	}
