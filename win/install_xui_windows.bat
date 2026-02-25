@echo off
setlocal
set "SELF_DIR=%~dp0"
set "PS1=%SELF_DIR%install_xui_windows.ps1"

if not exist "%PS1%" (
  echo [XUI] Missing installer: %PS1%
  exit /b 1
)

where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
  exit /b %errorlevel%
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
exit /b %errorlevel%
