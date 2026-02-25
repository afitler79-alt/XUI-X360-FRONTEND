@echo off
setlocal
set "SELF_DIR=%~dp0"
set "PS1=%SELF_DIR%build_win.ps1"

if not exist "%PS1%" (
  echo [XUI] Missing build script: %PS1%
  exit /b 1
)

where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
  exit /b %errorlevel%
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
exit /b %errorlevel%
