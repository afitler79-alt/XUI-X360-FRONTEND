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

set "PYTHON_LAUNCHER="

where py >nul 2>nul
if %errorlevel%==0 (
  py -3 -V >nul 2>nul
  if %errorlevel%==0 set "PYTHON_LAUNCHER=py -3"
)

if not defined PYTHON_LAUNCHER (
  where python >nul 2>nul
  if %errorlevel%==0 (
    python --version >nul 2>nul
    if %errorlevel%==0 set "PYTHON_LAUNCHER=python"
  )
)

if not defined PYTHON_LAUNCHER (
  where python3 >nul 2>nul
  if %errorlevel%==0 (
    python3 --version >nul 2>nul
    if %errorlevel%==0 set "PYTHON_LAUNCHER=python3"
  )
)

if not defined PYTHON_LAUNCHER (
  echo [XUI] Python 3 launcher not usable. Install Python 3.10+ from python.org and disable App Execution Alias for python/python3.
  exit /b 1
)

%PYTHON_LAUNCHER% "%DASH_PY%" %*
exit /b %errorlevel%
