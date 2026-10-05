#!/usr/bin/env python3
import os
import re
import shutil
import sys
import tarfile
import urllib.request
import zipfile
from pathlib import Path

REPO_URL = "https://raw.githubusercontent.com/afitler79-alt/XUI_360GAMES_REP/main/xui360repo.txt"
GAMES_DIR = Path("./games")
DOWNLOADS_DIR = Path("./downloads")


def log(msg):
    print(msg)


def ensure_dirs():
    GAMES_DIR.mkdir(exist_ok=True)
    DOWNLOADS_DIR.mkdir(exist_ok=True)


def download_text(url, dest):
    log("[+] Descargando lista de enlaces...")
    urllib.request.urlretrieve(url, dest)


def extract_google_drive_id(link):
    m = re.search(r"/file/d/([A-Za-z0-9_-]+)", link)
    if m:
        return m.group(1)
    return None


def download_drive_file(file_id, filename):
    url = f"https://drive.google.com/uc?export=download&id={file_id}"
    target = DOWNLOADS_DIR / filename
    log(f"[+] Descargando archivo: {file_id}")
    try:
        urllib.request.urlretrieve(url, target)
        return target
    except Exception as e:
        log(f"[-] Error al descargar {file_id}: {e}")
        return None


def extract_archive(file_path):
    log(f"[+] Descomprimiendo: {file_path.name}")
    try:
        if zipfile.is_zipfile(file_path):
            with zipfile.ZipFile(file_path, "r") as zf:
                zf.extractall(GAMES_DIR)
            return True
        if tarfile.is_tarfile(file_path):
            with tarfile.open(file_path, "r:*") as tf:
                tf.extractall(GAMES_DIR)
            return True
        shutil.copy2(file_path, GAMES_DIR / file_path.name)
        return True
    except Exception as e:
        log(f"[-] Error al descomprimir: {e}")
        return False


def process_links():
    links_file = DOWNLOADS_DIR / "xui360repo.txt"
    if not links_file.exists():
        log("[-] No se encontró la lista de enlaces.")
        return
    successful = 0
    failed = 0

    with open(links_file, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            link = line.strip()
            if not link or link.startswith("#"):
                continue

            file_id = extract_google_drive_id(link)
            if not file_id:
                log(f"[-] Enlace inválido: {link}")
                failed += 1
                continue

            filename = f"game_{file_id[:8]}.zip"
            downloaded = download_drive_file(file_id, filename)
            if not downloaded:
                failed += 1
                continue

            if extract_archive(downloaded):
                successful += 1
                try:
                    downloaded.unlink()
                except Exception:
                    pass
            else:
                failed += 1

    log(f"[+] Finalizado. Correctos: {successful} | Fallidos: {failed}")
    log(f"[+] Juegos descargados en: {GAMES_DIR.resolve()}")


def main():
    print("====================================")
    print("Xbox 360 Homebrew Games Store")
    print("====================================")
    ensure_dirs()
    download_text(REPO_URL, DOWNLOADS_DIR / "xui360repo.txt")
    process_links()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("\n[-] Interrumpido por el usuario.")
        sys.exit(1)
