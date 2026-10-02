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
- The main Linux installer automatically installs the official Xenia Canary AppImage on x86_64 and verifies the SHA-256 published by GitHub. Use `--skip-xenia` to opt out. From Games, choose Xenia Canary or select a legally owned `.iso`/`.xex` dump. Xenia does not run games directly from a regular PC DVD drive; a compatible disc dump is required.
- Open the Xbox Guide with F1 or Ctrl+G on the keyboard, or press the controller's Guide/Center button. The shortcut works while dashboard child controls have focus.
- The dashboard includes an Xbox Guide notification center, separate Missions and Achievements screens, editable local Gamer Cards, and a game search that opens the filtered local catalog. Profile and notification data remain local in `~/.xui/data`; these features do not sign in to Xbox Live.
- Social chat keeps bounded per-peer history in `~/.xui/data/social_conversations.json`; LAN sends are asynchronous and use matching-message acknowledgements when supported. LAN transport is not encrypted/authenticated, and the shared World relay is public—not end-to-end private. Declining a mandatory update no longer closes the dashboard.
- Launching helper apps and utilities keeps the dashboard process alive; the in-dashboard service utility now only reports status instead of restarting XUI. Applying an actual system update remains the intentional exception because it replaces installed files.
