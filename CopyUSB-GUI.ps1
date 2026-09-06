param(
    [string]$SourceRoot = '',
    [string[]]$DestDrives = @(),
    [string]$CheckScriptPath = '',
    [string]$SortScriptPath = '',
    [bool]$CheckAndSort = $true,
    [bool]$EnableCheck = $true,
    [bool]$EnableHash = $true,
    [int]$HashLastN = 100,
    [ValidateSet('CRC32', 'MD5', 'SHA256')]
    [string]$HashAlgorithm = 'MD5',
    [bool]$CheckDiskBeforeCopy = $false,
    [bool]$FixDiskErrors = $false,
    [string]$DiskCheckScriptPath = '',
    [string]$EjectScriptPath = '',
    [string]$RemountScriptPath = '',
    [string]$RemountCachePath = '',
    [ValidateSet(0, 1)]
    [int]$RemountDrive = 0,
    [ValidateSet('CopyWorkflow', 'CheckCopyHash', 'CheckUsbDisk', 'Mp3FatSort')]
    [string]$RunMode = 'CopyWorkflow',
    [string]$LogDir = '',
    [bool]$AutoYes = $false,
    [bool]$SkipEject = $false,
    [bool]$ForceMultiThreadUsb = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}
catch {
    Write-Error "Không thể nạp thư viện Windows Forms: $($_.Exception.Message)"
    exit 1
}
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:ScriptDir = Split-Path -Parent $PSCommandPath
$script:MasterScriptPath = Join-Path $script:ScriptDir 'master_copy_check_eject.ps1'
$script:DefaultLogDir = Join-Path $script:ScriptDir 'logs'
$script:RunProcess = $null
$script:LogOffset = 0L
$script:LastLogPath = $null
$script:GuiLogPath = $null
$script:RunStartedAt = $null

function Resolve-GuiDefault {
    param([AllowEmptyString()][string]$Value, [Parameter(Mandatory)][string]$Fallback)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Fallback }
    return $Value
}

function Get-UsbDriveLetters {
    $found = @()
    try {
        $found = @(Get-Disk -ErrorAction Stop |
            Where-Object { $_.BusType -eq 'USB' } |
            Get-Partition -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter } |
            ForEach-Object { '{0}:' -f $_.DriveLetter })
    }
    catch { $found = @() }
    if ($found.Count -eq 0) {
        try {
            $found = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType = 2" -ErrorAction Stop |
                Where-Object { $_.DeviceID } | ForEach-Object { $_.DeviceID })
        }
        catch { $found = @() }
    }
    return @($found | Sort-Object -Unique)
}

function Split-DriveText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @($Text -split '[,;\s]+' | ForEach-Object { $_.Trim() } |
        Where-Object { $_ } | ForEach-Object {
            if ($_ -notmatch ':$') { "$_`:" } else { $_ }
        } | Sort-Object -Unique)
}

function Quote-ProcessArgument {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"{0}"' -f ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1')
}

function Add-ProcessArgument {
    param([System.Collections.Generic.List[string]]$Arguments, [string]$Name, [AllowEmptyString()][string]$Value)
    [void]$Arguments.Add($Name)
    [void]$Arguments.Add((Quote-ProcessArgument $Value))
}

function Add-SwitchArgument {
    param([System.Collections.Generic.List[string]]$Arguments, [string]$Name, [bool]$Enabled)
    if ($Enabled) { [void]$Arguments.Add($Name) }
    else { [void]$Arguments.Add(('{0}:$false' -f $Name)) }
}

function Quote-PowerShellLiteral {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return "''" }
    return "'{0}'" -f ($Value -replace "'", "''")
}

function Get-LogDirectory {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $script:DefaultLogDir }
    if ([System.IO.Path]::IsPathRooted($Text)) { return $Text }
    return Join-Path $script:ScriptDir $Text
}

function Append-ConsoleText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $consoleText.AppendText($Text.TrimEnd("`r", "`n") + [Environment]::NewLine)
    $consoleText.SelectionStart = $consoleText.TextLength
    $consoleText.ScrollToCaret()
}

function Read-RunLog {
    $logDir = Get-LogDirectory $logDirText.Text.Trim()
    if (-not (Test-Path -LiteralPath $logDir)) { return }
    if (-not [string]::IsNullOrWhiteSpace($script:GuiLogPath) -and (Test-Path -LiteralPath $script:GuiLogPath -PathType Leaf)) {
        $candidate = Get-Item -LiteralPath $script:GuiLogPath
    }
    else {
        $candidate = Get-ChildItem -LiteralPath $logDir -Filter 'copycheckeject_*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $null -ne $script:RunStartedAt -and $_.LastWriteTime -ge $script:RunStartedAt } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if ($null -eq $candidate) { return }
    if ($script:LastLogPath -ne $candidate.FullName) {
        $script:LastLogPath = $candidate.FullName
        $script:LogOffset = 0L
        $logPathLabel.Text = "Log: $($candidate.FullName)"
        $consoleText.Clear()
    }
    try {
        $stream = [System.IO.File]::Open($candidate.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            if ($stream.Length -lt $script:LogOffset) { $script:LogOffset = 0L }
            $stream.Seek($script:LogOffset, 'Begin') | Out-Null
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
            try {
                $newText = $reader.ReadToEnd()
                $script:LogOffset = $stream.Position
            }
            finally { $reader.Dispose() }
        }
        finally { $stream.Dispose() }
        if ($newText) { Append-ConsoleText $newText }
    }
    catch { }
}

function Set-RunState {
    param([bool]$Running)
    $runButton.Enabled = -not $Running
    $stopButton.Enabled = $Running
    $exitButton.Enabled = -not $Running
    $sourceText.Enabled = -not $Running
    $destText.Enabled = -not $Running
    $scanButton.Enabled = -not $Running
    $browseSourceButton.Enabled = -not $Running
    $browseLogButton.Enabled = -not $Running
    $statusLabel.Text = if ($Running) { 'Đang chạy...' } else { 'Sẵn sàng' }
}

function Complete-RunIfNeeded {
    if ($null -eq $script:RunProcess -or -not $script:RunProcess.HasExited) { return }
    Read-RunLog
    $exitCode = $script:RunProcess.ExitCode
    $script:RunProcess.Dispose()
    $script:RunProcess = $null
    Set-RunState $false
    if ($exitCode -eq 0) {
        $statusLabel.Text = 'Đã hoàn tất. Kiểm tra log trước khi thoát.'
        Append-ConsoleText '[GUI] Quy trình kết thúc thành công (ExitCode=0).'
    }
    else {
        $statusLabel.Text = "Đã kết thúc với lỗi (ExitCode=$exitCode)."
        Append-ConsoleText "[GUI] Quy trình kết thúc với ExitCode=$exitCode."
    }
}

function New-ToolCommand {
    $mode = [string]$runModeCombo.SelectedItem
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $logPath = $script:GuiLogPath

    switch ($mode) {
        'CheckCopyHash' {
            [void]$parts.Add('&')
            [void]$parts.Add((Quote-PowerShellLiteral $checkScriptText.Text.Trim()))
            [void]$parts.Add('-SourceRoot')
            [void]$parts.Add((Quote-PowerShellLiteral $sourceText.Text.Trim()))
            foreach ($drive in (Split-DriveText $destText.Text)) {
                [void]$parts.Add('-DestDrives')
                [void]$parts.Add((Quote-PowerShellLiteral $drive))
            }
            [void]$parts.Add('-HashLastN')
            [void]$parts.Add((Quote-PowerShellLiteral $hashLastNText.Text.Trim()))
            [void]$parts.Add('-HashAlgorithm')
            [void]$parts.Add((Quote-PowerShellLiteral ([string]$hashAlgorithmCombo.SelectedItem)))
            [void]$parts.Add('-NoConfirm')
            [void]$parts.Add('-NoPause')
            [void]$parts.Add('-LogFile')
            [void]$parts.Add((Quote-PowerShellLiteral $logPath))
            if ($enableHashCheck.Checked) { [void]$parts.Add('-Hash') }
        }
        'CheckUsbDisk' {
            [void]$parts.Add('&')
            [void]$parts.Add((Quote-PowerShellLiteral $diskCheckScriptText.Text.Trim()))
            foreach ($drive in (Split-DriveText $destText.Text)) {
                [void]$parts.Add('-DestDrives')
                [void]$parts.Add((Quote-PowerShellLiteral $drive))
            }
            [void]$parts.Add('-NoConfirm')
            [void]$parts.Add('-NoPause')
            [void]$parts.Add('-LogFile')
            [void]$parts.Add((Quote-PowerShellLiteral $logPath))
            if ($fixDiskCheck.Checked) { [void]$parts.Add('-Fix') }
        }
        'Mp3FatSort' {
            [void]$parts.Add('&')
            [void]$parts.Add((Quote-PowerShellLiteral $sortScriptText.Text.Trim()))
            $deviceText = ((Split-DriveText $destText.Text) | ForEach-Object { $_.ToLowerInvariant() }) -join ','
            [void]$parts.Add('-Device')
            [void]$parts.Add((Quote-PowerShellLiteral $deviceText))
            [void]$parts.Add('-Mode')
            [void]$parts.Add((Quote-PowerShellLiteral ([string]$sortModeCombo.SelectedItem)))
            [void]$parts.Add('-SortScope')
            [void]$parts.Add((Quote-PowerShellLiteral ([string]$sortScopeCombo.SelectedItem)))
            [void]$parts.Add('-FileFilter')
            [void]$parts.Add((Quote-PowerShellLiteral ([string]$sortFilterCombo.SelectedItem)))
            [void]$parts.Add('-ThrottleLimit')
            [void]$parts.Add((Quote-PowerShellLiteral $throttleText.Text.Trim()))
            if ($sortForceCheck.Checked) { [void]$parts.Add('-Force') }
            if ($sortNoParallelCheck.Checked) { [void]$parts.Add('-NoParallel') }
            return ((($parts -join ' ') + " *>&1 | Tee-Object -FilePath {0} -Append; `$toolExit = `$LASTEXITCODE; exit `$toolExit") -f (Quote-PowerShellLiteral $logPath))
        }
        default { throw "RunMode không được hỗ trợ: $mode" }
    }
    return ($parts -join ' ')
}

function New-MasterCommand {
    $parts = New-Object 'System.Collections.Generic.List[string]'
    [void]$parts.Add('&')
    [void]$parts.Add((Quote-PowerShellLiteral $script:MasterScriptPath))
    [void]$parts.Add('-SourceRoot')
    [void]$parts.Add((Quote-PowerShellLiteral $sourceText.Text.Trim()))
    foreach ($drive in (Split-DriveText $destText.Text)) {
        [void]$parts.Add('-DestDrives')
        [void]$parts.Add((Quote-PowerShellLiteral $drive))
    }
    foreach ($item in @(
        @('-CheckScriptPath', $checkScriptText.Text.Trim()),
        @('-SortScriptPath', $sortScriptText.Text.Trim()),
        @('-HashLastN', $hashLastNText.Text.Trim()),
        @('-HashAlgorithm', [string]$hashAlgorithmCombo.SelectedItem),
        @('-DiskCheckScriptPath', $diskCheckScriptText.Text.Trim()),
        @('-EjectScriptPath', $ejectScriptText.Text.Trim()),
        @('-RemountScriptPath', $remountScriptText.Text.Trim()),
        @('-RemountCachePath', $remountCacheText.Text.Trim()),
        @('-RemountDrive', [string]$remountDriveCombo.SelectedItem),
        @('-LogDir', $logDirText.Text.Trim())
    )) {
        [void]$parts.Add($item[0])
        [void]$parts.Add((Quote-PowerShellLiteral ([string]$item[1])))
    }
    [void]$parts.Add('-CheckAndSort')
    [void]$parts.Add($(if ($sortToolCheck.Checked) { '$true' } else { '$false' }))
    [void]$parts.Add('-EnableCheck')
    [void]$parts.Add($(if ($checkCopyToolCheck.Checked) { '$true' } else { '$false' }))
    [void]$parts.Add(($(if ($enableHashCheck.Checked) { '-EnableHash:$true' } else { '-EnableHash:$false' })))
    if ($diskToolCheck.Checked) { [void]$parts.Add('-CheckDiskBeforeCopy') }
    if ($fixDiskCheck.Checked) { [void]$parts.Add('-FixDiskErrors') }
    if ($autoYesCheck.Checked) { [void]$parts.Add('-AutoYes') }
    if ($skipEjectCheck.Checked) { [void]$parts.Add('-SkipEject') }
    if ($forceMultiThreadCheck.Checked) { [void]$parts.Add('-ForceMultiThreadUsb') }
    [void]$parts.Add('-NoPause')
    return ($parts -join ' ')
}

function Start-MasterRun {
    $mode = [string]$runModeCombo.SelectedItem
    if ($mode -eq 'CopyWorkflow' -and -not (Test-Path -LiteralPath $script:MasterScriptPath -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show("Không tìm thấy script: $script:MasterScriptPath", 'CopyUSB', 'OK', 'Error') | Out-Null
        return
    }
    if ($mode -in @('CopyWorkflow', 'CheckCopyHash') -and -not (Test-Path -LiteralPath $sourceText.Text.Trim() -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show('SourceRoot không tồn tại hoặc không phải thư mục.', 'CopyUSB', 'OK', 'Warning') | Out-Null
        return
    }
    if (@(Split-DriveText $destText.Text).Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Hãy chọn ít nhất một USB đích.', 'CopyUSB', 'OK', 'Warning') | Out-Null
        return
    }
    $logDir = Get-LogDirectory $logDirText.Text.Trim()
    try {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $logDirText.Text = $logDir
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Không thể tạo thư mục log: $($_.Exception.Message)", 'CopyUSB', 'OK', 'Error') | Out-Null
        return
    }
    $shell = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($null -eq $shell) { $shell = Get-Command powershell.exe -ErrorAction SilentlyContinue }
    if ($null -eq $shell) {
        [System.Windows.Forms.MessageBox]::Show('Không tìm thấy PowerShell trên máy.', 'CopyUSB', 'OK', 'Error') | Out-Null
        return
    }
    $script:RunStartedAt = [DateTime]::Now
    $script:LastLogPath = $null
    $script:LogOffset = 0L
    if ($mode -eq 'CopyWorkflow') {
        $script:GuiLogPath = $null
    }
    else {
        $script:GuiLogPath = Join-Path $logDir ("copyusb_gui_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        New-Item -ItemType File -Path $script:GuiLogPath -Force | Out-Null
    }
    $consoleText.Clear()
    Append-ConsoleText ("[GUI] Đã khởi động chế độ: {0}. Log sẽ được cập nhật liên tục." -f $mode)
    try {
        # Dùng -Command để các giá trị $true/$false được PowerShell con nhận là
        # Boolean thật; truyền chúng qua -File sẽ biến thành chuỗi và lỗi bind.
        $commandText = if ($mode -eq 'CopyWorkflow') { New-MasterCommand } else { New-ToolCommand }
        $argText = '-NoProfile -ExecutionPolicy Bypass -Command {0}' -f (Quote-ProcessArgument $commandText)
        $windowStyle = if ($showConsoleCheck.Checked) { 'Normal' } else { 'Hidden' }
        $script:RunProcess = Start-Process -FilePath $shell.Source -ArgumentList $argText -WorkingDirectory $script:ScriptDir -WindowStyle $windowStyle -PassThru
        Set-RunState $true
        $statusLabel.Text = "Đang chạy (PID $($script:RunProcess.Id))..."
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Không thể khởi động PowerShell: $($_.Exception.Message)", 'CopyUSB', 'OK', 'Error') | Out-Null
    }
}

function Stop-MasterRun {
    if ($null -eq $script:RunProcess) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show('Dừng tiến trình đang chạy? Có thể còn file chưa hoàn tất.', 'CopyUSB', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }
    try { Stop-Process -Id $script:RunProcess.Id -Force -ErrorAction Stop; Append-ConsoleText '[GUI] Đã dừng tiến trình.' }
    catch { Append-ConsoleText "[GUI] Không thể dừng tiến trình: $($_.Exception.Message)" }
}

function Close-Gui {
    if ($null -ne $script:RunProcess -and -not $script:RunProcess.HasExited) {
        [System.Windows.Forms.MessageBox]::Show('Hãy dừng hoặc chờ tiến trình hoàn tất trước khi thoát.', 'CopyUSB', 'OK', 'Warning') | Out-Null
        return
    }
    $form.Close()
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'CopyUSB - Copy tới nhiều USB'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1120, 780)
$form.MinimumSize = New-Object System.Drawing.Size(900, 650)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$mainLayout = New-Object System.Windows.Forms.TableLayoutPanel
$mainLayout.Dock = 'Fill'
$mainLayout.ColumnCount = 1
$mainLayout.RowCount = 3
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 360)))
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$form.Controls.Add($mainLayout)
$settingsPanel = New-Object System.Windows.Forms.Panel
$settingsPanel.Dock = 'Fill'
$settingsPanel.AutoScroll = $true
$settingsPanel.Padding = New-Object System.Windows.Forms.Padding(8)
[void]$mainLayout.Controls.Add($settingsPanel, 0, 0)
$settings = New-Object System.Windows.Forms.TableLayoutPanel
$settings.Dock = 'Top'
$settings.AutoSize = $true
$settings.AutoSizeMode = 'GrowAndShrink'
$settings.MinimumSize = New-Object System.Drawing.Size(980, 0)
$settings.ColumnCount = 4
$settings.RowCount = 9
[void]$settings.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 145)))
[void]$settings.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 50)))
[void]$settings.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 145)))
[void]$settings.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 50)))
for ($row = 0; $row -lt 9; $row++) { [void]$settings.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize'))) }
[void]$settingsPanel.Controls.Add($settings)

function New-Label { param([string]$Text); $label = New-Object System.Windows.Forms.Label; $label.Text = $Text; $label.AutoSize = $true; $label.Anchor = 'Left'; $label.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 3); return $label }
function New-TextBox { param([string]$Text); $box = New-Object System.Windows.Forms.TextBox; $box.Text = $Text; $box.Dock = 'Fill'; $box.Margin = New-Object System.Windows.Forms.Padding(3); return $box }

$sourceText = New-TextBox (Resolve-GuiDefault $SourceRoot (Join-Path $script:ScriptDir 'Test'))
$destText = New-TextBox ($(if ($DestDrives.Count -gt 0) { $DestDrives -join ', ' } else { (Get-UsbDriveLetters) -join ', ' }))
$checkScriptText = New-TextBox (Resolve-GuiDefault $CheckScriptPath (Join-Path $script:ScriptDir 'check_copy_hash.ps1'))
$sortScriptText = New-TextBox (Resolve-GuiDefault $SortScriptPath (Join-Path $script:ScriptDir 'Mp3FatSort.ps1'))
$diskCheckScriptText = New-TextBox (Resolve-GuiDefault $DiskCheckScriptPath (Join-Path $script:ScriptDir 'Check-UsbDisk.ps1'))
$ejectScriptText = New-TextBox (Resolve-GuiDefault $EjectScriptPath (Join-Path $script:ScriptDir 'removedrv.ps1'))
$remountScriptText = New-TextBox (Resolve-GuiDefault $RemountScriptPath (Join-Path $script:ScriptDir 'Remount-Usb.ps1'))
$remountCacheText = New-TextBox (Resolve-GuiDefault $RemountCachePath (Join-Path $script:ScriptDir 'usb_remount_cache.json'))
$logDirText = New-TextBox (Resolve-GuiDefault $LogDir $script:DefaultLogDir)
$hashLastNText = New-TextBox ([string]$HashLastN)
$hashAlgorithmCombo = New-Object System.Windows.Forms.ComboBox
$hashAlgorithmCombo.DropDownStyle = 'DropDownList'
[void]$hashAlgorithmCombo.Items.AddRange(@('CRC32', 'MD5', 'SHA256'))
$hashAlgorithmCombo.SelectedItem = $HashAlgorithm
$hashAlgorithmCombo.Dock = 'Fill'
$remountDriveCombo = New-Object System.Windows.Forms.ComboBox
$remountDriveCombo.DropDownStyle = 'DropDownList'
[void]$remountDriveCombo.Items.AddRange(@('0', '1'))
$remountDriveCombo.SelectedItem = [string]$RemountDrive
$remountDriveCombo.Dock = 'Fill'
$remountDriveCombo.Enabled = $false
$runModeCombo = New-Object System.Windows.Forms.ComboBox
$runModeCombo.DropDownStyle = 'DropDownList'
[void]$runModeCombo.Items.AddRange(@('CopyWorkflow', 'CheckCopyHash', 'CheckUsbDisk', 'Mp3FatSort'))
$runModeCombo.SelectedItem = $RunMode
$runModeCombo.Dock = 'Fill'
$sortModeCombo = New-Object System.Windows.Forms.ComboBox
$sortModeCombo.DropDownStyle = 'DropDownList'
[void]$sortModeCombo.Items.AddRange(@('CheckOnly', 'SortOnlyAuto', 'CheckAndSort'))
$sortModeCombo.SelectedItem = 'CheckAndSort'
$sortModeCombo.Width = 125
$sortScopeCombo = New-Object System.Windows.Forms.ComboBox
$sortScopeCombo.DropDownStyle = 'DropDownList'
[void]$sortScopeCombo.Items.AddRange(@('Both', 'FoldersOnly', 'FilesOnly'))
$sortScopeCombo.SelectedItem = 'Both'
$sortScopeCombo.Width = 105
$sortFilterCombo = New-Object System.Windows.Forms.ComboBox
$sortFilterCombo.DropDownStyle = 'DropDownList'
[void]$sortFilterCombo.Items.AddRange(@('MediaOnly', 'AllFiles'))
$sortFilterCombo.SelectedItem = 'MediaOnly'
$sortFilterCombo.Width = 105
$throttleText = New-TextBox '4'
$throttleText.Width = 45
$browseSourceButton = New-Object System.Windows.Forms.Button
$browseSourceButton.Text = 'Chọn...'
$browseSourceButton.AutoSize = $true
$browseSourceButton.Add_Click({ $dialog = New-Object System.Windows.Forms.FolderBrowserDialog; $dialog.SelectedPath = $sourceText.Text; if ($dialog.ShowDialog() -eq 'OK') { $sourceText.Text = $dialog.SelectedPath }; $dialog.Dispose() })
$scanButton = New-Object System.Windows.Forms.Button
$scanButton.Text = 'Quét USB'
$scanButton.AutoSize = $true
$scanButton.Add_Click({ $usb = @(Get-UsbDriveLetters); if ($usb.Count -gt 0) { $destText.Text = $usb -join ', ' } else { [System.Windows.Forms.MessageBox]::Show('Không tìm thấy USB đang mount.', 'CopyUSB', 'OK', 'Information') | Out-Null } })
$browseLogButton = New-Object System.Windows.Forms.Button
$browseLogButton.Text = 'Mở thư mục'
$browseLogButton.AutoSize = $true
$browseLogButton.Add_Click({ if (Test-Path -LiteralPath $logDirText.Text) { Start-Process explorer.exe -ArgumentList (Quote-ProcessArgument $logDirText.Text) } })

function Add-FieldRow {
    param([int]$Row, [string]$Label, [System.Windows.Forms.Control]$Control, [int]$Column = 0, [System.Windows.Forms.Control]$Extra = $null)
    [void]$settings.Controls.Add((New-Label $Label), $Column, $Row)
    [void]$settings.Controls.Add($Control, $Column + 1, $Row)
    if ($null -ne $Extra) { [void]$settings.Controls.Add($Extra, $Column + 2, $Row) }
}
Add-FieldRow 0 'SourceRoot' $sourceText 0 $browseSourceButton
Add-FieldRow 1 'DestDrives (USB)' $destText 0 $scanButton
Add-FieldRow 2 'CheckScriptPath' $checkScriptText 0
Add-FieldRow 2 'SortScriptPath' $sortScriptText 2
Add-FieldRow 3 'DiskCheckScriptPath' $diskCheckScriptText 0
Add-FieldRow 3 'EjectScriptPath' $ejectScriptText 2
Add-FieldRow 4 'RemountScriptPath' $remountScriptText 0
Add-FieldRow 4 'RemountCachePath' $remountCacheText 2
Add-FieldRow 5 'LogDir' $logDirText 0 $browseLogButton
Add-FieldRow 6 'HashLastN (0=all)' $hashLastNText 2
Add-FieldRow 6 'HashAlgorithm' $hashAlgorithmCombo 0
Add-FieldRow 7 'Chế độ chạy' $runModeCombo 0
# Add-FieldRow 7 'RemountDrive' $remountDriveCombo 2
Add-FieldRow 7 'Sort mode độc lập' $sortModeCombo 2

function New-CheckBox { param([string]$Text, [bool]$Checked); $box = New-Object System.Windows.Forms.CheckBox; $box.Text = $Text; $box.Checked = $Checked; $box.AutoSize = $true; return $box }
$checkCopyToolCheck = New-CheckBox 'Enable check_copy_hash' $EnableCheck
$sortToolCheck = New-CheckBox 'Enable Mp3FatSort' $CheckAndSort
$enableHashCheck = New-CheckBox 'Bật hash' $EnableHash
$diskToolCheck = New-CheckBox 'Enable Check-UsbDisk trước copy' $CheckDiskBeforeCopy
$fixDiskCheck = New-CheckBox 'Fix lỗi disk' $FixDiskErrors
$autoYesCheck = New-CheckBox 'AutoYes (bỏ prompt xác nhận)' $AutoYes
$skipEjectCheck = New-CheckBox 'SkipEject' $SkipEject
$forceMultiThreadCheck = New-CheckBox 'ForceMultiThreadUsb' $ForceMultiThreadUsb
$showConsoleCheck = New-CheckBox 'Hiện console PowerShell riêng' $true
$sortForceCheck = New-CheckBox 'Sort -Force' $true
$sortNoParallelCheck = New-CheckBox 'Sort tuần tự' $false
$checks = New-Object System.Windows.Forms.FlowLayoutPanel
$checks.Dock = 'Fill'; $checks.AutoSize = $true; $checks.WrapContents = $true
[void]$checks.Controls.Add((New-Label 'SortScope'))
[void]$checks.Controls.Add($sortScopeCombo)
[void]$checks.Controls.Add((New-Label 'FileFilter'))
[void]$checks.Controls.Add($sortFilterCombo)
[void]$checks.Controls.Add((New-Label 'Throttle'))
[void]$checks.Controls.Add($throttleText)
[void]$checks.Controls.Add($checkCopyToolCheck)
[void]$checks.Controls.Add($enableHashCheck)
[void]$checks.Controls.Add($diskToolCheck)
[void]$checks.Controls.Add($fixDiskCheck)
[void]$checks.Controls.Add($sortToolCheck)
[void]$checks.Controls.Add($sortForceCheck)
[void]$checks.Controls.Add($sortNoParallelCheck)
[void]$checks.Controls.Add($autoYesCheck)
[void]$checks.Controls.Add($skipEjectCheck)
[void]$checks.Controls.Add($forceMultiThreadCheck)
[void]$checks.Controls.Add($showConsoleCheck)
$hashLastNText.Enabled = $checkCopyToolCheck.Checked
$hashAlgorithmCombo.Enabled = $checkCopyToolCheck.Checked
$enableHashCheck.Enabled = $checkCopyToolCheck.Checked
$checkCopyToolCheck.Add_CheckedChanged({
    $hashLastNText.Enabled = $checkCopyToolCheck.Checked
    $hashAlgorithmCombo.Enabled = $checkCopyToolCheck.Checked
    $enableHashCheck.Enabled = $checkCopyToolCheck.Checked
})
[void]$settings.Controls.Add($checks, 0, 7); $settings.SetColumnSpan($checks, 4)
$warningLabel = New-Object System.Windows.Forms.Label
$warningLabel.Text = 'Lưu ý: cleanup/format/eject có thể thay đổi dữ liệu trên USB. Hãy kiểm tra cấu hình trước khi chạy.'
$warningLabel.ForeColor = [System.Drawing.Color]::DarkGoldenrod; $warningLabel.AutoSize = $true; $warningLabel.Dock = 'Fill'
[void]$settings.Controls.Add($warningLabel, 0, 8); $settings.SetColumnSpan($warningLabel, 4)

$consoleGroup = New-Object System.Windows.Forms.GroupBox
$consoleGroup.Text = 'Console / log thời gian thực'; $consoleGroup.Dock = 'Fill'; $consoleGroup.Padding = New-Object System.Windows.Forms.Padding(8)
[void]$mainLayout.Controls.Add($consoleGroup, 0, 1)
$consoleText = New-Object System.Windows.Forms.TextBox
$consoleText.Multiline = $true; $consoleText.ReadOnly = $true; $consoleText.ScrollBars = 'Both'; $consoleText.WordWrap = $false
$consoleText.BackColor = [System.Drawing.Color]::Black; $consoleText.ForeColor = [System.Drawing.Color]::LightGray; $consoleText.Font = New-Object System.Drawing.Font('Consolas', 9); $consoleText.Dock = 'Fill'
[void]$consoleGroup.Controls.Add($consoleText)

$bottom = New-Object System.Windows.Forms.FlowLayoutPanel
$bottom.Dock = 'Fill'; $bottom.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4); $bottom.AutoSize = $true
[void]$mainLayout.Controls.Add($bottom, 0, 2)
$runButton = New-Object System.Windows.Forms.Button; $runButton.Text = 'Chạy copy'; $runButton.Width = 115; $runButton.Add_Click({ Start-MasterRun })
$stopButton = New-Object System.Windows.Forms.Button; $stopButton.Text = 'Dừng'; $stopButton.Width = 90; $stopButton.Enabled = $false; $stopButton.Add_Click({ Stop-MasterRun })
$exitButton = New-Object System.Windows.Forms.Button; $exitButton.Text = 'Thoát'; $exitButton.Width = 90; $exitButton.Add_Click({ Close-Gui })
$statusLabel = New-Object System.Windows.Forms.Label; $statusLabel.Text = 'Sẵn sàng'; $statusLabel.AutoSize = $true; $statusLabel.Margin = New-Object System.Windows.Forms.Padding(12, 8, 8, 3)
$logPathLabel = New-Object System.Windows.Forms.Label; $logPathLabel.Text = 'Log: chưa có lần chạy'; $logPathLabel.AutoSize = $true; $logPathLabel.Margin = New-Object System.Windows.Forms.Padding(12, 8, 8, 3)
foreach ($control in @($runButton, $stopButton, $exitButton, $statusLabel, $logPathLabel)) { [void]$bottom.Controls.Add($control) }

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({ Read-RunLog; Complete-RunIfNeeded })
$timer.Start()
$form.Add_Resize({
    if ($settingsPanel.ClientSize.Width -gt 20) {
        $settings.Width = [Math]::Max(980, $settingsPanel.ClientSize.Width - 20)
    }
})
$form.Add_FormClosing({ if ($null -ne $script:RunProcess -and -not $script:RunProcess.HasExited) { $_.Cancel = $true; Close-Gui } })
Set-RunState $false
$settings.Width = [Math]::Max(980, $settingsPanel.ClientSize.Width - 20)
$form.Add_Shown({ $sourceText.Focus() })
[System.Windows.Forms.Application]::Run($form)
