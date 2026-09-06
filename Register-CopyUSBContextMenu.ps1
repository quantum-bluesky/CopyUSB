param(
    [ValidateSet('Install', 'Uninstall', 'Status')]
    [string]$Action = 'Install',
    [string]$GuiScriptPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
if ($Action -eq 'Install') {
    if ([string]::IsNullOrWhiteSpace($GuiScriptPath)) {
        $GuiScriptPath = Join-Path $scriptDir 'CopyUSB-GUI.ps1'
    }
    $GuiScriptPath = [System.IO.Path]::GetFullPath($GuiScriptPath)
    if (-not (Test-Path -LiteralPath $GuiScriptPath -PathType Leaf)) {
        throw "Không tìm thấy GUI script: $GuiScriptPath"
    }
}

$menuKey = 'HKCU:\Software\Classes\Directory\shell\CopyUSB-GUI'
$commandKey = Join-Path $menuKey 'command'

function Get-PowerShellPath {
    $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($null -eq $command) { $command = Get-Command powershell.exe -ErrorAction SilentlyContinue }
    if ($null -eq $command) { throw 'Không tìm thấy powershell.exe hoặc pwsh.exe.' }
    return $command.Source
}

function Get-RegistryCommand {
    param([string]$ShellPath, [string]$ScriptPath)
    return '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -SourceRoot "%1"' -f $ShellPath, $ScriptPath
}

switch ($Action) {
    'Install' {
        $shellPath = Get-PowerShellPath
        New-Item -Path $menuKey -Force | Out-Null
        New-Item -Path $commandKey -Force | Out-Null
        Set-ItemProperty -LiteralPath $menuKey -Name '(Default)' -Value 'CopyUSB: copy folder to USB'
        Set-ItemProperty -LiteralPath $menuKey -Name 'Icon' -Value "$shellPath,0"
        Set-ItemProperty -LiteralPath $commandKey -Name '(Default)' -Value (Get-RegistryCommand $shellPath $GuiScriptPath)
        Write-Output "Đã đăng ký context menu tại: $menuKey"
        Write-Output 'Trong File Explorer, click phải vào folder và chọn "CopyUSB: copy folder tới USB".'
    }
    'Uninstall' {
        if (Test-Path -LiteralPath $menuKey) {
            Remove-Item -LiteralPath $menuKey -Recurse -Force
            Write-Output "Đã gỡ context menu: $menuKey"
        }
        else { Write-Output 'Context menu chưa được đăng ký.' }
    }
    'Status' {
        if (Test-Path -LiteralPath $commandKey) {
            $value = (Get-ItemProperty -LiteralPath $commandKey -Name '(Default)').'(Default)'
            Write-Output "Đã đăng ký: $value"
        }
        else { Write-Output 'Chưa đăng ký context menu.' }
    }
}
