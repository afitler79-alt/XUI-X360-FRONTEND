@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "SELF_DIR=%~dp0"
set "PSH="

where pwsh >nul 2>nul
if %errorlevel%==0 (
  set "PSH=pwsh"
) else (
  where powershell >nul 2>nul
  if %errorlevel%==0 (
    set "PSH=powershell"
  )
)

if not defined PSH (
  echo [XUI] PowerShell not found. Cannot continue.
  exit /b 1
)

echo [INFO] XUI master installer
echo [INFO] Preparing execution policy and unblocking files...
%PSH% -NoProfile -ExecutionPolicy Bypass -Command "Set-ExecutionPolicy -Scope Process Bypass -Force" >nul 2>nul
%PSH% -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%SELF_DIR%' -Recurse -File -ErrorAction SilentlyContinue ^| Unblock-File -ErrorAction SilentlyContinue" >nul 2>nul

call :detect_python
if not defined PY_OK (
  echo [INFO] Python 3 not detected. Attempting automatic install with winget...
  call :install_python
  call :detect_python
)

if not defined PY_OK (
  echo [ERROR] Python 3.10+ is required.
  echo [HINT] Install from https://www.python.org/downloads/windows/
  echo [HINT] Enable "Add Python to PATH" and disable App Execution Alias for python/python3.
  exit /b 1
)

where git >nul 2>nul
if %errorlevel% neq 0 (
  echo [INFO] Git not found. Attempting automatic install with winget...
  call :install_git
)

echo [INFO] Running XUI installer...
call "%SELF_DIR%install_xui_windows.bat" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo [ERROR] XUI installer failed with code %RC%.
  exit /b %RC%
)

echo [DONE] XUI installed successfully.
exit /b 0

:detect_python
set "PY_OK="
where py >nul 2>nul
if !errorlevel!==0 (
  py -3 -V >nul 2>nul
  if !errorlevel!==0 set "PY_OK=1"
)
if not defined PY_OK (
  where python >nul 2>nul
  if !errorlevel!==0 (
    python --version >nul 2>nul
    if !errorlevel!==0 set "PY_OK=1"
  )
)
if not defined PY_OK (
  where python3 >nul 2>nul
  if !errorlevel!==0 (
    python3 --version >nul 2>nul
    if !errorlevel!==0 set "PY_OK=1"
  )
)
exit /b 0

:install_python
where winget >nul 2>nul
if %errorlevel% neq 0 (
  echo [WARN] winget is not available. Skipping automatic Python install.
  exit /b 1
)
winget install -e --id Python.Python.3.12 --scope user --accept-source-agreements --accept-package-agreements --disable-interactivity
if %errorlevel% neq 0 (
  winget install -e --id Python.Python.3.11 --scope user --accept-source-agreements --accept-package-agreements --disable-interactivity
)
set "PATH=%PATH%;%LocalAppData%\Programs\Python\Python312;%LocalAppData%\Programs\Python\Python312\Scripts;%LocalAppData%\Programs\Python\Python311;%LocalAppData%\Programs\Python\Python311\Scripts;%LocalAppData%\Programs\Python\Launcher"
exit /b 0

:install_git
where winget >nul 2>nul
if %errorlevel% neq 0 (
  echo [WARN] winget is not available. Skipping automatic Git install.
  exit /b 1
)
winget install -e --id Git.Git --scope user --accept-source-agreements --accept-package-agreements --disable-interactivity
set "PATH=%PATH%;%ProgramFiles%\Git\cmd;%LocalAppData%\Programs\Git\cmd"
exit /b 0
