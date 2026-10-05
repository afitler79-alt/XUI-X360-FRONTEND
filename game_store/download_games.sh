#!/bin/bash
set -e

REPO_URL="https://raw.githubusercontent.com/afitler79-alt/XUI_360GAMES_REP/main/xui360repo.txt"
GAMES_DIR="./games"
DOWNLOADS_DIR="./downloads"

mkdir -p "$GAMES_DIR" "$DOWNLOADS_DIR"

echo "===================================="
echo "Xbox 360 Homebrew Games Store"
echo "===================================="

echo "[+] Descargando lista de enlaces..."
curl -L "$REPO_URL" -o "$DOWNLOADS_DIR/xui360repo.txt"

count=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  [[ "$line" =~ ^# ]] && continue

  file_id=$(printf '%s' "$line" | sed -E 's#.*?/file/d/([A-Za-z0-9_-]+).*#\1#')
  [ -z "$file_id" ] && continue

  file_name="game_${file_id:0:8}.zip"
  target="$DOWNLOADS_DIR/$file_name"

  echo "[+] Descargando $file_id"
  curl -L "https://drive.google.com/uc?export=download&id=$file_id" -o "$target"

  if unzip -l "$target" >/dev/null 2>&1; then
    echo "[+] Descomprimiendo ZIP..."
    unzip -q "$target" -d "$GAMES_DIR"
  elif tar -tf "$target" >/dev/null 2>&1; then
    echo "[+] Descomprimiendo TAR..."
    tar -xf "$target" -C "$GAMES_DIR"
  else
    echo "[+] Copiando archivo sin descomprimir..."
    cp "$target" "$GAMES_DIR/"
  fi

  rm -f "$target"
  count=$((count+1))
done < "$DOWNLOADS_DIR/xui360repo.txt"

echo "[+] Finalizado. Descargados: $count"
echo "[+] Juegos en: $GAMES_DIR"
