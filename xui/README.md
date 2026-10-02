XUI Minimal Installer
=====================

What this repo contains
- `xui11.sh` - single-file installer/script that creates `~/.xui`, copies assets, writes a PyQt dashboard, helpers and autostart units.
- asset files: `applogo.png`, `bootlogo.png`, `startup.mp3`, `startup.mp4`, sound effects.
- `requirements.txt` - Python runtime dependencies for the dashboard and helper scripts.

Quick install (Linux / WSL)

1. From this directory, make the maintained installer executable and run it
	without installing system packages:

```bash
chmod +x xui11.sh.fixed.sh
./xui11.sh.fixed.sh --no-auto-install
```

2. To explicitly allow the installer to install system dependencies and tools:

```bash
./xui11.sh.fixed.sh --yes-install
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
./xui11.sh.fixed.sh --yes-install
```


Development

- Create a virtual env and install Python deps:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Notes

- The installer generates placeholder images when original files are missing (requires `python3` + `Pillow`; startup video generation also requires `ffmpeg`).
- System package installation is opt-in via `--yes-install`; `--no-auto-install` explicitly disables it.
