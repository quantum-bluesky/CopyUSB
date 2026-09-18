@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-CopyUSB.ps1" %*
if errorlevel 1 (
  echo Build failed. Read the error above.
  pause
  exit /b 1
)
echo CopyUSB package is ready. YAFS compilation is a separate step.
pause
