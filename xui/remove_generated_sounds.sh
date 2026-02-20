#!/usr/bin/env bash
set -euo pipefail
# Script to remove generated placeholder sound files from the repo `assets/` directory.
ASSETS_DIR="$(cd "$(dirname "$0")" && pwd)/assets"
if [ ! -d "$ASSETS_DIR" ]; then
    echo "[INFO] No assets directory found at $ASSETS_DIR" && exit 0
fi
echo "[INFO] Removing generated placeholder sound files from $ASSETS_DIR"
files=(
  click.wav click.mp3
  hover.wav hover.mp3
  startup.wav startup.mp3
  boot.wav boot.mp3
  select.wav select.mp3
  back.wav back.mp3
  open.wav open.mp3
  close.wav close.mp3
  confirm.wav confirm.mp3
  cancel.wav cancel.mp3
  navigate.wav navigate.mp3
  scroll.wav scroll.mp3
  archievements.mp3
  "10. Select A.mp3"
  "14. Back.mp3"
)
for f in "${files[@]}"; do
  target="$ASSETS_DIR/$f"
  if [ -f "$target" ]; then
    rm -f "$target" && echo "Removed $target"
  fi
done
echo "[INFO] Removal complete. If you want, place your files into user_sounds/ and run the installer." 
