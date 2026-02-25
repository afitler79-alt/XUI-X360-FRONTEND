@echo off
setlocal
set "XUI_HOME=%USERPROFILE%\.xui"
set "DASH_PY=%XUI_HOME%\dashboard\pyqt_dashboard_improved.py"

if not exist "%DASH_PY%" (
  echo [XUI] Missing dashboard: %DASH_PY%
  exit /b 1
)

set "QTWEBENGINE_CHROMIUM_FLAGS=--renderer-process-limit=2 --disk-cache-size=16777216 --media-cache-size=8388608 --disable-background-networking --disable-component-update --enable-low-end-device-mode"
set "QTWEBENGINE_DISABLE_SANDBOX=1"
set "QT_OPENGL=software"

where py >nul 2>nul
if %errorlevel%==0 (
  py -3 "%DASH_PY%" %*
  exit /b %errorlevel%
)

where python >nul 2>nul
if %errorlevel%==0 (
  python "%DASH_PY%" %*
  exit /b %errorlevel%
)

echo [XUI] Python 3 not found. Install Python 3.10+ and run install_xui_windows.ps1 again.
exit /b 1
