param(
    [ValidateNotNullOrEmpty()]
    [string]$MasterScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'master_copy_check_eject.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-FileExists {
    param(
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw ("Khong tim thay file: {0}" -f $Path)
    }
}

function Assert-ContainsText {
    param(
        [ValidateNotNullOrEmpty()]
        [string]$Content,

        [ValidateNotNullOrEmpty()]
        [string]$ExpectedText,

        [ValidateNotNullOrEmpty()]
        [string]$FailureMessage
    )

    if ($Content.IndexOf($ExpectedText, [System.StringComparison]::Ordinal) -lt 0) {
        throw $FailureMessage
    }
}

function Assert-BeforeText {
    param(
        [ValidateNotNullOrEmpty()]
        [string]$Content,

        [ValidateNotNullOrEmpty()]
        [string]$FirstText,

        [ValidateNotNullOrEmpty()]
        [string]$SecondText,

        [ValidateNotNullOrEmpty()]
        [string]$FailureMessage
    )

    $firstIndex = $Content.IndexOf($FirstText, [System.StringComparison]::Ordinal)
    $secondIndex = $Content.IndexOf($SecondText, [System.StringComparison]::Ordinal)
    if ($firstIndex -lt 0 -or $secondIndex -lt 0 -or $firstIndex -ge $secondIndex) {
        throw $FailureMessage
    }
}

function Test-PowerShellSyntax {
    param(
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $messages = $errors | ForEach-Object { $_.Message }
        throw ("Parse PowerShell that bai: {0}" -f ($messages -join '; '))
    }
}

function Get-RemountSimulation {
    param(
        [ValidateSet(0, 1)]
        [int]$RemountDrive
    )

    [PSCustomObject]@{
        RemountDrive            = $RemountDrive
        Capture                 = if ($RemountDrive -eq 1) { 'Enabled' } else { 'Skipped' }
        AdminWarning            = if ($RemountDrive -eq 1) { 'Conditional' } else { 'Skipped' }
        AutoRemountBeforeCopy   = if ($RemountDrive -eq 1) { 'Enabled' } else { 'Skipped' }
        AutoRemountAfterFailure = if ($RemountDrive -eq 1) { 'Enabled' } else { 'Skipped' }
    }
}

try {
    $resolvedMasterScriptPath = (Resolve-Path -LiteralPath $MasterScriptPath).ProviderPath
    Assert-FileExists -Path $resolvedMasterScriptPath
    Test-PowerShellSyntax -Path $resolvedMasterScriptPath

    $content = Get-Content -LiteralPath $resolvedMasterScriptPath -Raw -Encoding UTF8

    Assert-ContainsText -Content $content `
        -ExpectedText '[ValidateSet(0, 1)]' `
        -FailureMessage 'Thieu ValidateSet(0,1) cho tham so RemountDrive.'
    Assert-ContainsText -Content $content `
        -ExpectedText '[int]$RemountDrive = 0' `
        -FailureMessage 'Thieu tham so RemountDrive mac dinh = 0.'
    Assert-ContainsText -Content $content `
        -ExpectedText '$script:RemountDriveEnabled = ($RemountDrive -eq 1)' `
        -FailureMessage 'Thieu co noi bo RemountDriveEnabled.'
    Assert-ContainsText -Content $content `
        -ExpectedText 'if ($script:RemountDriveEnabled -and (Test-Path $RemountScriptPath) -and (-not $script:IsAdmin)) {' `
        -FailureMessage 'Canh bao admin cho remount chua duoc gate bang RemountDriveEnabled.'
    Assert-ContainsText -Content $content `
        -ExpectedText 'Write-Log "RemountDrive=0 -> bỏ qua capture thông tin remount và tự động remount." "WARN"' `
        -FailureMessage 'Thieu log bo qua capture/remount khi RemountDrive=0.'
    Assert-BeforeText -Content $content `
        -FirstText 'if (-not $script:RemountDriveEnabled) {' `
        -SecondText 'Write-Log "Capture thông tin remount cho các ổ USB hợp lệ..."' `
        -FailureMessage 'Nhanh capture remount chua duoc dat sau dieu kien RemountDriveEnabled.'
    Assert-ContainsText -Content $content `
        -ExpectedText 'Write-Log ("RemountDrive=0 -> bỏ qua tự động remount cho ổ {0}." -f $DriveLetter) "WARN" -Drive $DriveLetter' `
        -FailureMessage 'Thieu log bo qua auto-remount truoc khi copy.'
    Assert-ContainsText -Content $content `
        -ExpectedText 'Write-Log ("Ổ {0} không còn sẵn sàng (có thể bị rút). RemountDrive=0 -> bỏ qua tự động remount." -f $drv) "ERROR" -Drive $drv' `
        -FailureMessage 'Thieu log bo qua auto-remount sau khi copy loi.'

    $simulations = @(0, 1) | ForEach-Object { Get-RemountSimulation -RemountDrive $_ }

    Write-Host "PASS: RemountDrive flag contract is present in master_copy_check_eject.ps1"
    $simulations | Format-Table -AutoSize
}
catch {
    Write-Error $_
    exit 1
}
