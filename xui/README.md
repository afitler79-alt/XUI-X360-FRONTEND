XUI Minimal Installer
=====================

What this repo contains
- `xui11.sh` - single-file installer/script that creates `~/.xui`, copies assets, writes a PyQt dashboard, helpers and autostart units.
- asset files: `applogo.png`, `bootlogo.png`, `startup.mp3`, `startup.mp4`, sound effects.
- `requirements.txt` - Python runtime dependencies for the dashboard and helper scripts.

Quick install (Linux / WSL)

1. Make script executable and run:

```bash
chmod +x xui11.sh
./xui11.sh
```

2. If you want the installer to try to auto-install media tools, re-run with:

```bash
AUTO_INSTALL_TOOLS=1 ./xui11.sh
```

3. To run the dashboard immediately:

```bash
~/.xui/bin/xui_startup_and_dashboard.sh
```

Kubuntu Noble L4T (NVIDIA Jetson / Noble)
----------------------------------------

- On Kubuntu for Noble / L4T devices ensure you have the following packages installed: `python3`, `python3-pip`, `python3-venv`, `ffmpeg`, `mpv` (optional), and system image libraries (libjpeg, libpng).
- Create a virtualenv and install Python deps from `requirements.txt` then run the installer script. If you copied this repo from Windows, run `prepare_for_linux.sh` first to normalize scripts.

Example commands:

```bash
./prepare_for_linux.sh
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
./xui11.sh --yes-install
```


Development

- Create a virtual env and install Python deps:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Notes

- The installer will generate placeholder images/audio when original files are missing (requires `python3` + `Pillow` and/or `ffmpeg`).
- The script avoids performing privileged package installs unless `AUTO_INSTALL_TOOLS=1` is set and a compatible package manager is detected.
