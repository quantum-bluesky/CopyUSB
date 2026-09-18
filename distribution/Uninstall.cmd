@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-CopyUSB.ps1"
if errorlevel 1 (
  echo Uninstall failed. See the error above.
  pause
  exit /b 1
)
echo Uninstall complete.
pause
