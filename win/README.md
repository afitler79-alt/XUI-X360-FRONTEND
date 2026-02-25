# XUI Windows Integration

This folder is generated from the master installer `xui11.sh.fixed.sh`.

## Files

- `install_xui_master.bat`: master installer (dependency bootstrap + XUI install)
- `install_xui_windows.ps1`: installs XUI on Windows under `%USERPROFILE%\.xui`
- `install_xui_windows.bat`: one-click launcher for the PowerShell installer
- `xui_start_windows.bat`: launcher used by the installer
- `xui_update_check.py`: mandatory update checker for Windows branch
- `extract_xui_payload.py`: extracts Python payloads from `xui11.sh.fixed.sh`
- `build_win.ps1`: creates a distributable ZIP bundle with everything needed
- `build_win.bat`: one-click launcher for `build_win.ps1`

## Install (Recommended)

```bat
install_xui_master.bat
```

## Install (PowerShell direct)

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\install_xui_windows.ps1
```

Optional:

```powershell
.\install_xui_windows.ps1 -EnableAutostart
```

Use a custom Windows update branch:

```powershell
.\install_xui_windows.ps1 -UpdateBranch Windows
```

One-click from cmd:

```bat
install_xui_windows.bat
```

## Build distributable ZIP (Windows)

```powershell
.\build_win.ps1
```

or:

```bat
build_win.bat
```

## Regenerate this folder from Linux master

```bash
bash xui11.sh.fixed.sh --export-win-only
```
