@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-CopyUSB.ps1"
if errorlevel 1 (
  echo Installation failed. See the error above.
  pause
  exit /b 1
)
echo Installation complete. Check any warnings above. Use the Desktop shortcut or the printed launch command.
pause
