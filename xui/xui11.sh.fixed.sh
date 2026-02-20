#!/usr/bin/env bash
set -euo pipefail

# Minimal, cleaned installer for XUI dashboard
    # Fixes: defines missing helpers, removes duplicated blocks, and ensures a runnable flow

USER_HOME="${HOME:-/home/$(whoami)}"
XUI_DIR="$USER_HOME/.xui"
DATA_DIR="$XUI_DIR/data"
BIN_DIR="$XUI_DIR/bin"
DASH_DIR="$XUI_DIR/dashboard"
CASINO_DIR="$XUI_DIR/casino"
GAMES_DIR="$XUI_DIR/games"
ASSETS_DIR="$XUI_DIR/assets"
LOG_DIR="$XUI_DIR/logs"
BACKUP_DIR="$XUI_DIR/backups"
SYSTEMD_USER_DIR="$USER_HOME/.config/systemd/user"
AUTOSTART_DIR="$USER_HOME/.config/autostart"

info(){ echo -e "[INFO] $*"; }
warn(){ echo -e "[WARN] $*" >&2; }
check_cmd(){ command -v "$1" >/dev/null 2>&1; }

run_as_root(){
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
        return $?
    fi
    if check_cmd sudo; then
        sudo "$@"
        return $?
    fi
    warn "sudo not found and current user is not root; cannot run: $*"
    return 1
}

wait_for_apt_lock(){
    if ! check_cmd apt; then
        return 0
    fi
    if [ "${XUI_SKIP_APT_WAIT:-0}" = "1" ]; then
        info "Skipping apt/dpkg wait (XUI_SKIP_APT_WAIT=1)"
        return 0
    fi
    local waited=0
    local step=2
    local max_wait="${XUI_APT_WAIT_SECONDS:-180}"
    if ! [[ "$max_wait" =~ ^[0-9]+$ ]]; then
        max_wait=180
    fi
    while true; do
        local lock_busy=0
        if check_cmd fuser; then
            for lf in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock; do
                [ -e "$lf" ] || continue
                if fuser "$lf" >/dev/null 2>&1; then
                    lock_busy=1
                    break
                fi
            done
        fi
        if [ "$lock_busy" -eq 0 ]; then
            # Fallback: process check when lock files can't be inspected.
            if pgrep -x apt >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 || pgrep -f unattended-upgrade >/dev/null 2>&1; then
                lock_busy=1
            fi
        fi

        if [ "$lock_busy" -eq 1 ]; then
            if [ "$waited" -ge "$max_wait" ]; then
                warn "APT/DPKG lock still busy after ${max_wait}s; continuing anyway"
                break
            fi
            info "Waiting apt/dpkg lock (${waited}s/${max_wait}s)..."
            if [ "$waited" -eq 0 ]; then
                info "Tip: use --skip-apt-wait or --apt-wait-seconds 30"
            fi
            sleep "$step"
            waited=$((waited + step))
            continue
        fi
        break
    done
}

apt_safe_update(){
    wait_for_apt_lock
    run_as_root apt update
}

apt_safe_install(){
    wait_for_apt_lock
    run_as_root apt install -y "$@"
}

# Simple confirmation helper. Respects AUTO_CONFIRM=1 for automation.
confirm(){
    if [ "${AUTO_CONFIRM:-0}" = "1" ] || [ "${AUTO_INSTALL_TOOLS:-0}" = "1" ]; then
        return 0
    fi
    while true; do
        printf "%s [y/N]: " "$1"
        read -r ans || return 1
        case "$ans" in
            [Yy]|[Yy][Ee][Ss]) return 0;;
            [Nn]|[Nn][Oo]|"") return 1;;
        esac
    done
}

install_dependencies(){
    if [ "${AUTO_INSTALL_TOOLS:-1}" != "1" ]; then
        info "AUTO_INSTALL_TOOLS=0; skipping dependency installation"
        return 0
    fi
    if ! check_cmd python3; then
        warn "python3 not found; cannot continue dependency setup"
        return 0
    fi

    mkdir -p "$BIN_DIR"
    # Always create python launcher wrapper first
    cat > "$BIN_DIR/xui_python.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [ -x "$HOME/.xui/.venv/bin/python" ]; then
  exec "$HOME/.xui/.venv/bin/python" "$@"
fi
exec python3 "$@"
BASH
    chmod +x "$BIN_DIR/xui_python.sh" || true

    info "Installing system dependencies (best effort)"
    if command -v apt >/dev/null 2>&1; then
        local arch_now
        arch_now="$(uname -m)"
        apt_safe_update || warn "apt update failed"
        # Install critical runtime first (must succeed for dashboard)
        apt_safe_install \
            python3 python3-pip python3-venv python3-pyqt5 python3-pyqt5.qtmultimedia python3-pil || warn "Core apt dependencies failed"
        apt_safe_install python3-pyqt5.qtwebengine || warn "Optional apt package missing: python3-pyqt5.qtwebengine"
        # Optional tools (can fail without breaking dashboard runtime)
        apt_safe_install \
            ffmpeg mpv jq xdotool curl ca-certificates iproute2 bc \
            xclip xsel rofi feh maim scrot udisks2 p7zip-full \
            retroarch lutris || warn "Some apt packages failed to install"
        # Windows compatibility (best effort): Wine + Winetricks + ARM helpers
        if [ "$arch_now" = "x86_64" ] || [ "$arch_now" = "amd64" ]; then
            apt_safe_install wine wine64 winetricks || warn "Wine/Winetricks install failed on x86_64"
        elif [ "$arch_now" = "aarch64" ] || [ "$arch_now" = "arm64" ]; then
            apt_safe_install wine64 winetricks || true
            apt_safe_install box64 box86 qemu-user-static || warn "ARM compatibility packages failed (box64/box86/qemu)"
            info "AArch64 detected: x86 Windows .exe may need box64 + x86 Wine build"
        fi
        # Optional gaming/compat packages (best effort one by one)
        for pkg in flatpak steam-installer steamcmd box64 box86 qemu-user-static retroarch lutris heroic heroic-games-launcher; do
            apt_safe_install "$pkg" || true
        done
    elif command -v dnf >/dev/null 2>&1; then
        run_as_root dnf install -y \
            python3 python3-pip python3-virtualenv python3-qt5 python3-pillow \
            ffmpeg mpv jq xdotool curl iproute bc \
            xclip xsel rofi feh scrot udisks2 p7zip retroarch lutris || warn "Some dnf packages failed to install"
        run_as_root dnf install -y python3-qt5-webengine || true
        run_as_root dnf install -y wine winetricks || true
        for pkg in flatpak steam box64 fex-emu qemu-user-static retroarch lutris heroic-games-launcher; do
            run_as_root dnf install -y "$pkg" || true
        done
    elif command -v pacman >/dev/null 2>&1; then
        run_as_root pacman -Syu --noconfirm \
            python python-pip python-virtualenv pyqt5 python-pillow \
            ffmpeg mpv jq xdotool curl iproute2 bc \
            xclip xsel rofi feh scrot maim udisks2 p7zip retroarch lutris || warn "Some pacman packages failed to install"
        run_as_root pacman -S --noconfirm python-pyqt5-webengine || true
        run_as_root pacman -S --noconfirm wine winetricks || true
        for pkg in flatpak steam box64 qemu-user-static retroarch lutris heroic-games-launcher; do
            run_as_root pacman -S --noconfirm "$pkg" || true
        done
    else
        warn "No known package manager found; skipping system package installation"
    fi

    # Validate Python modules and fallback to local venv if needed
    if python3 - <<'PY' >/dev/null 2>&1
import PyQt5, PIL
PY
    then
        info "Python modules available: PyQt5, Pillow"
        return 0
    fi

    warn "PyQt5/Pillow missing in system Python; creating local venv fallback"
    VENV_DIR="$XUI_DIR/.venv"
    python3 -m venv "$VENV_DIR" >/dev/null 2>&1 || warn "Failed to create venv at $VENV_DIR"
    if [ -x "$VENV_DIR/bin/pip" ]; then
        "$VENV_DIR/bin/pip" install --upgrade pip >/dev/null 2>&1 || true
        "$VENV_DIR/bin/pip" install PyQt5 PyQtWebEngine Pillow pygame evdev >/dev/null 2>&1 || warn "venv pip install failed"
    fi

    # Validate fallback runtime
    if [ -x "$XUI_DIR/.venv/bin/python" ]; then
        if "$XUI_DIR/.venv/bin/python" - <<'PY' >/dev/null 2>&1
import PyQt5, PIL
PY
        then
            info "venv runtime ready (PyQt5/Pillow)"
        else
            warn "venv created but PyQt5/Pillow still unavailable"
        fi
    fi
}

install_browser(){
    # Best-effort installer for a browser or a no-op stub so calls don't fail.
    if [ "${AUTO_INSTALL_TOOLS:-0}" != "1" ]; then
        info "AUTO_INSTALL_TOOLS not set; skipping browser install"
        return 0
    fi
    # Prefer chromium/firefox and don't fail on distro package differences
    if command -v apt >/dev/null 2>&1; then
        apt_safe_update || true
        if ! apt_safe_install chromium-browser; then
            if ! apt_safe_install chromium; then
                apt_safe_install firefox || warn "Failed to install browser via apt"
            fi
        fi
        return 0
    elif command -v dnf >/dev/null 2>&1; then
        run_as_root dnf install -y chromium || warn "Failed to install chromium via dnf"
        return 0
    elif command -v pacman >/dev/null 2>&1; then
        run_as_root pacman -S --noconfirm chromium || warn "Failed to install chromium via pacman"
        return 0
    fi
    warn "No supported package manager found for automatic browser install; please install a browser (chromium/firefox) manually"
}

parse_args(){
    # Auto-install enabled by default; use --no-auto-install to disable
    AUTO_INSTALL_TOOLS=1
    XUI_INSTALL_SYSTEM=1
    XUI_USE_EXTERNAL_DASHBOARD=0
    XUI_SKIP_APT_WAIT=0
    XUI_APT_WAIT_SECONDS="${XUI_APT_WAIT_SECONDS:-180}"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --yes-install|-y)
                AUTO_INSTALL_TOOLS=1
                XUI_INSTALL_SYSTEM=1
                shift
                ;;
            --no-auto-install)
                AUTO_INSTALL_TOOLS=0
                XUI_INSTALL_SYSTEM=0
                shift
                ;;
            --use-external-dashboard)
                XUI_USE_EXTERNAL_DASHBOARD=1
                shift
                ;;
            --skip-apt-wait)
                XUI_SKIP_APT_WAIT=1
                shift
                ;;
            --apt-wait-seconds)
                if [ "${2:-}" != "" ] && [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                    XUI_APT_WAIT_SECONDS="$2"
                    shift 2
                else
                    warn "--apt-wait-seconds requires numeric value"
                    shift
                fi
                ;;
            --help|-h)
                echo "Usage: $0 [--yes-install|-y] [--no-auto-install] [--use-external-dashboard] [--skip-apt-wait] [--apt-wait-seconds N]"; exit 0 ;;
            *)
                # pass-through unknown args
                shift
                ;;
        esac
    done
    export AUTO_INSTALL_TOOLS XUI_INSTALL_SYSTEM XUI_USE_EXTERNAL_DASHBOARD XUI_SKIP_APT_WAIT XUI_APT_WAIT_SECONDS
}

ensure_dirs(){
  mkdir -p "$ASSETS_DIR" "$BIN_DIR" "$DASH_DIR" "$DATA_DIR" "$SYSTEMD_USER_DIR" "$AUTOSTART_DIR" || true
}

# Minimal safe stubs for functions that may be referenced later in the script but
# which are optional. Each stub logs and returns success so the installer flow
# doesn't fail when running quickly.
create_basics(){
    info "create_basics: creating minimal app layout"
    mkdir -p "$XUI_DIR/apps" || true
    return 0
}

post_create_assets(){
    info "post_create_assets: no-op placeholder"
    return 0
}

write_apps_utilities(){
    info "write_apps_utilities: writing lightweight utilities (stub)"
    # create an example launcher script
    cat > "$BIN_DIR/xui_example_app.sh" <<'SH' || true
#!/usr/bin/env bash
echo "XUI example app launched"
SH
    chmod +x "$BIN_DIR/xui_example_app.sh" || true
}

write_more_apps(){
    info "write_more_apps: no-op"
    return 0
}

write_even_more_apps(){
    info "write_even_more_apps: no-op"
    return 0
}

write_battery_tools(){
    info "write_battery_tools: no-op"
    return 0
}

install_compat_layer(){
    info "install_compat_layer: writing Steam/x86 compatibility helpers"
    mkdir -p "$BIN_DIR" "$DATA_DIR"

cat > "$BIN_DIR/xui_compat_status.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
echo "=== XUI Compatibility Status ==="
echo "Arch: $(uname -m)"
echo "steam: $(command -v steam >/dev/null 2>&1 && echo yes || echo no)"
echo "flatpak-steam: $(command -v flatpak >/dev/null 2>&1 && flatpak info com.valvesoftware.Steam >/dev/null 2>&1 && echo yes || echo no)"
echo "retroarch: $(command -v retroarch >/dev/null 2>&1 && echo yes || echo no)"
echo "flatpak-retroarch: $(command -v flatpak >/dev/null 2>&1 && flatpak info org.libretro.RetroArch >/dev/null 2>&1 && echo yes || echo no)"
echo "lutris: $(command -v lutris >/dev/null 2>&1 && echo yes || echo no)"
echo "flatpak-lutris: $(command -v flatpak >/dev/null 2>&1 && flatpak info net.lutris.Lutris >/dev/null 2>&1 && echo yes || echo no)"
echo "heroic: $( (command -v heroic >/dev/null 2>&1 || command -v heroic-games-launcher >/dev/null 2>&1) && echo yes || echo no )"
echo "flatpak-heroic: $(command -v flatpak >/dev/null 2>&1 && flatpak info com.heroicgameslauncher.hgl >/dev/null 2>&1 && echo yes || echo no)"
echo "box64: $(command -v box64 >/dev/null 2>&1 && echo yes || echo no)"
echo "box86: $(command -v box86 >/dev/null 2>&1 && echo yes || echo no)"
echo "fex: $(command -v fex-emu >/dev/null 2>&1 && echo yes || echo no)"
echo "qemu-x86_64: $(command -v qemu-x86_64 >/dev/null 2>&1 && echo yes || echo no)"
echo "wine: $(command -v wine >/dev/null 2>&1 && echo yes || echo no)"
echo "winetricks: $(command -v winetricks >/dev/null 2>&1 && echo yes || echo no)"
BASH
    chmod +x "$BIN_DIR/xui_compat_status.sh"

    cat > "$BIN_DIR/xui_run_x86.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <x86_binary> [args...]"
  exit 1
fi
BIN="$1"
shift || true
if command -v box64 >/dev/null 2>&1; then
  exec box64 "$BIN" "$@"
elif command -v fex-emu >/dev/null 2>&1; then
  exec fex-emu "$BIN" "$@"
elif command -v qemu-x86_64 >/dev/null 2>&1; then
  exec qemu-x86_64 "$BIN" "$@"
else
  echo "No x86 runner found (box64/fex/qemu-x86_64)."
  exit 1
fi
BASH
    chmod +x "$BIN_DIR/xui_run_x86.sh"

    cat > "$BIN_DIR/xui_install_box64.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
as_root(){
  if [ "$(id -u)" -eq 0 ]; then "$@"; return $?; fi
  if command -v sudo >/dev/null 2>&1; then sudo "$@"; return $?; fi
  echo "sudo required: $*" >&2
  return 1
}
wait_apt(){
  local t=0
  while pgrep -x apt >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 || pgrep -f unattended-upgrade >/dev/null 2>&1; do
    [ "$t" -ge 180 ] && break
    echo "waiting apt/dpkg lock... ${t}s"
    sleep 2
    t=$((t+2))
  done
}
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
  echo "Host arch is $ARCH. Box64 is typically needed only on arm64."
  exit 0
fi
if command -v box64 >/dev/null 2>&1; then
  echo "box64 already installed"
  exit 0
fi
if command -v apt >/dev/null 2>&1; then
  wait_apt
  as_root apt update || true
  wait_apt
  as_root apt install -y box64 box86 || as_root apt install -y box64 || true
elif command -v dnf >/dev/null 2>&1; then
  as_root dnf install -y box64 || true
elif command -v pacman >/dev/null 2>&1; then
  as_root pacman -S --noconfirm box64 || true
else
  echo "Unsupported package manager for auto-install."
fi
if command -v box64 >/dev/null 2>&1; then
  echo "box64 installed correctly."
  exit 0
fi
echo "box64 package not available in current repositories."
echo "Install manually for your distro and re-run xui_compat_status.sh"
exit 1
BASH
    chmod +x "$BIN_DIR/xui_install_box64.sh"

    cat > "$BIN_DIR/xui_install_steam.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
as_root(){
  if [ "$(id -u)" -eq 0 ]; then "$@"; return $?; fi
  if command -v sudo >/dev/null 2>&1; then sudo "$@"; return $?; fi
  echo "sudo required: $*" >&2
  return 1
}
wait_apt(){
  local t=0
  while pgrep -x apt >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 || pgrep -f unattended-upgrade >/dev/null 2>&1; do
    [ "$t" -ge 180 ] && break
    echo "waiting apt/dpkg lock... ${t}s"
    sleep 2
    t=$((t+2))
  done
}
ensure_flatpak(){
  if command -v flatpak >/dev/null 2>&1; then
    return 0
  fi
  if command -v apt >/dev/null 2>&1; then
    wait_apt
    as_root apt update || true
    wait_apt
    as_root apt install -y flatpak || true
  elif command -v dnf >/dev/null 2>&1; then
    as_root dnf install -y flatpak || true
  elif command -v pacman >/dev/null 2>&1; then
    as_root pacman -S --noconfirm flatpak || true
  fi
  command -v flatpak >/dev/null 2>&1
}
ARCH=$(uname -m)
if command -v steam >/dev/null 2>&1; then
  echo "Steam already installed."
  exit 0
fi

if [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "amd64" ]; then
  if command -v apt >/dev/null 2>&1; then
    wait_apt
    as_root apt update || true
    wait_apt
    as_root apt install -y steam-installer || as_root apt install -y steam || true
  elif command -v dnf >/dev/null 2>&1; then
    as_root dnf install -y steam || true
  elif command -v pacman >/dev/null 2>&1; then
    as_root pacman -S --noconfirm steam || true
  fi
else
  # ARM64 path: install box64 and optionally Flatpak Steam.
  "$HOME/.xui/bin/xui_install_box64.sh" || true
  ensure_flatpak || true
  if command -v flatpak >/dev/null 2>&1; then
    if ! flatpak remote-list | grep -q '^flathub'; then
      flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
    fi
    flatpak install -y flathub com.valvesoftware.Steam || true
  fi
fi

if ! command -v steam >/dev/null 2>&1; then
  ensure_flatpak || true
fi
if ! command -v steam >/dev/null 2>&1 && command -v flatpak >/dev/null 2>&1; then
  if ! flatpak remote-list | grep -q '^flathub'; then
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
  fi
  flatpak install -y flathub com.valvesoftware.Steam || true
fi

if command -v steam >/dev/null 2>&1; then
  echo "Steam installed successfully."
  exit 0
fi
if command -v flatpak >/dev/null 2>&1 && flatpak info com.valvesoftware.Steam >/dev/null 2>&1; then
  echo "Flatpak Steam installed successfully."
  exit 0
fi
echo "Steam installation was not completed automatically."
echo "Use xui_compat_status.sh to inspect available compatibility tools."
exit 1
BASH
    chmod +x "$BIN_DIR/xui_install_steam.sh"

cat > "$BIN_DIR/xui_steam.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
ARCH=$(uname -m)
CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
  shift || true
fi

has_steam(){
  if command -v steam >/dev/null 2>&1; then
    return 0
  fi
  if command -v flatpak >/dev/null 2>&1 && flatpak info com.valvesoftware.Steam >/dev/null 2>&1; then
    return 0
  fi
  if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    if command -v box64 >/dev/null 2>&1; then
      for c in \
        "$HOME/.local/share/Steam/ubuntu12_64/steam" \
        "$HOME/.steam/steam/ubuntu12_64/steam" \
        "/usr/lib/steam/steam" \
        "/usr/games/steam"; do
        if [ -x "$c" ]; then
          return 0
        fi
      done
    fi
  fi
  return 1
}

if [ "$CHECK_ONLY" = "1" ]; then
  if has_steam; then
    echo "steam: available"
    exit 0
  fi
  echo "steam: missing"
  exit 1
fi

if command -v steam >/dev/null 2>&1; then
  exec steam "$@"
fi

if command -v flatpak >/dev/null 2>&1 && flatpak info com.valvesoftware.Steam >/dev/null 2>&1; then
  exec flatpak run com.valvesoftware.Steam "$@"
fi

if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
  if command -v box64 >/dev/null 2>&1; then
    for c in \
      "$HOME/.local/share/Steam/ubuntu12_64/steam" \
      "$HOME/.steam/steam/ubuntu12_64/steam" \
      "/usr/lib/steam/steam" \
      "/usr/games/steam"; do
      if [ -x "$c" ]; then
        exec "$HOME/.xui/bin/xui_run_x86.sh" "$c" "$@"
      fi
    done
  fi
fi

echo "Steam not available yet."
echo "Run: $HOME/.xui/bin/xui_install_steam.sh"
exit 1
BASH
    chmod +x "$BIN_DIR/xui_steam.sh"

    cat > "$BIN_DIR/xui_install_wine.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
as_root(){
  if [ "$(id -u)" -eq 0 ]; then "$@"; return $?; fi
  if command -v sudo >/dev/null 2>&1; then sudo "$@"; return $?; fi
  echo "sudo required: $*" >&2
  return 1
}
ARCH=$(uname -m)
echo "Installing Wine runtime for $ARCH (best effort)"
if command -v apt >/dev/null 2>&1; then
  as_root apt update || true
  if [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "amd64" ]; then
    as_root apt install -y wine wine64 winetricks || true
  else
    as_root apt install -y wine64 winetricks || true
    as_root apt install -y box64 box86 qemu-user-static || true
    echo "ARM64 note: running x86 Windows .exe usually needs box64 + x86 Wine build."
  fi
elif command -v dnf >/dev/null 2>&1; then
  as_root dnf install -y wine winetricks || true
elif command -v pacman >/dev/null 2>&1; then
  as_root pacman -S --noconfirm wine winetricks || true
else
  echo "Unsupported package manager for auto-install"
  exit 1
fi
echo "wine: $(command -v wine >/dev/null 2>&1 && echo yes || echo no)"
echo "winetricks: $(command -v winetricks >/dev/null 2>&1 && echo yes || echo no)"
BASH
    chmod +x "$BIN_DIR/xui_install_wine.sh"

    cat > "$BIN_DIR/xui_wine_run.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
TARGET=${1:-}
shift || true
if [ -z "$TARGET" ] || [ ! -e "$TARGET" ]; then
  echo "Usage: $0 <file.exe|installer.msi> [args...]"
  exit 1
fi
ARCH=$(uname -m)
if command -v wine >/dev/null 2>&1; then
  exec wine "$TARGET" "$@"
fi
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
  if command -v box64 >/dev/null 2>&1; then
    for c in /usr/local/bin/wine64 /opt/wine/bin/wine64 "$HOME/wine/bin/wine64"; do
      if [ -x "$c" ]; then
        exec box64 "$c" "$TARGET" "$@"
      fi
    done
  fi
fi
echo "Wine runtime not available."
echo "Run: $HOME/.xui/bin/xui_install_wine.sh"
exit 1
BASH
    chmod +x "$BIN_DIR/xui_wine_run.sh"

    cat > "$BIN_DIR/xui_scan_media_games.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
OUT="$HOME/.xui/data/media_games.txt"
mkdir -p "$(dirname "$OUT")"
tmp="$(mktemp)"

collect_mounts(){
  # Removable and optical mounts first.
  if command -v lsblk >/dev/null 2>&1; then
    lsblk -rno MOUNTPOINT,RM,TYPE,TRAN 2>/dev/null | while read -r mp rm typ tr; do
      [ -n "${mp:-}" ] || continue
      if [ "$rm" = "1" ] || [ "$typ" = "rom" ] || [ "$tr" = "usb" ]; then
        echo "$mp"
      fi
    done
  fi
  # Common desktop automount locations.
  [ -d "/run/media/$USER" ] && find "/run/media/$USER" -mindepth 1 -maxdepth 2 -type d 2>/dev/null || true
  [ -d "/media/$USER" ] && find "/media/$USER" -mindepth 1 -maxdepth 2 -type d 2>/dev/null || true
  [ -d "/media" ] && find "/media" -mindepth 1 -maxdepth 2 -type d 2>/dev/null || true
  [ -d "/mnt" ] && find "/mnt" -mindepth 1 -maxdepth 2 -type d 2>/dev/null || true
}

mapfile -t mps < <(collect_mounts | awk 'NF' | sort -u)
if [ "${#mps[@]}" -eq 0 ]; then
  echo "No mounted USB/DVD media found." | tee "$OUT"
  exit 1
fi

{
  echo "=== Mounted media ==="
  for mp in "${mps[@]}"; do
    echo "$mp"
  done
  echo
  echo "=== Candidate games/apps ==="
} > "$tmp"

for mp in "${mps[@]}"; do
  [ -d "$mp" ] || continue
  find "$mp" -maxdepth 6 -type f \
    \( -iname '*.exe' -o -iname '*.msi' -o -iname '*.bat' -o -iname '*.AppImage' -o -iname '*.sh' -o -iname '*.desktop' -o -iname '*.x86_64' -o -iname '*.iso' -o -iname '*.chd' -o -iname '*.cue' \) \
    2>/dev/null
done | sort -u >> "$tmp"

if ! grep -q '^/' "$tmp"; then
  echo "No launch candidates found." >> "$tmp"
fi

mv "$tmp" "$OUT"
cat "$OUT"
BASH
    chmod +x "$BIN_DIR/xui_scan_media_games.sh"

    cat > "$BIN_DIR/xui_open_tray_scan.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
XUI="$HOME/.xui/bin"
echo "Open/Close tray and scan USB/DVD for games..."
if command -v eject >/dev/null 2>&1; then
  eject -T >/dev/null 2>&1 || true
  sleep 2
fi

"$XUI/xui_scan_media_games.sh" || true
LIST="$HOME/.xui/data/media_games.txt"
if [ ! -f "$LIST" ]; then
  exit 0
fi
mapfile -t files < <(grep '^/' "$LIST" || true)
if [ "${#files[@]}" -eq 0 ]; then
  echo
  echo "No executable/game candidate found."
  exit 0
fi

echo
echo "Select a file to launch:"
i=1
for f in "${files[@]}"; do
  echo "[$i] $f"
  i=$((i+1))
done
echo "[0] Cancel"
read -r -p "Choice: " idx
case "$idx" in
  ''|*[!0-9]*) echo "Invalid choice"; exit 1 ;;
esac
[ "$idx" -eq 0 ] && exit 0
if [ "$idx" -lt 1 ] || [ "$idx" -gt "${#files[@]}" ]; then
  echo "Out of range"
  exit 1
fi
target="${files[$((idx-1))]}"
ext="${target##*.}"
ext="$(printf "%s" "$ext" | tr '[:upper:]' '[:lower:]')"

case "$ext" in
  exe|msi|bat)
    exec "$XUI/xui_wine_run.sh" "$target"
    ;;
  appimage)
    chmod +x "$target" 2>/dev/null || true
    exec "$target"
    ;;
  sh)
    exec bash "$target"
    ;;
  desktop)
    if command -v gtk-launch >/dev/null 2>&1; then
      name="$(basename "$target" .desktop)"
      exec gtk-launch "$name"
    fi
    exec xdg-open "$target"
    ;;
  iso|chd|cue)
    if [ -x "$XUI/xui_retroarch.sh" ]; then
      exec "$XUI/xui_retroarch.sh" "$target"
    fi
    exec xdg-open "$target"
    ;;
  *)
    exec xdg-open "$target"
    ;;
esac
BASH
    chmod +x "$BIN_DIR/xui_open_tray_scan.sh"

    if [ "${AUTO_INSTALL_TOOLS:-0}" = "1" ]; then
      arch_now="$(uname -m)"
      if [ "$arch_now" = "x86_64" ] || [ "$arch_now" = "amd64" ]; then
        if command -v apt >/dev/null 2>&1; then
          apt_safe_install steam-installer || true
        fi
      elif [ "$arch_now" = "aarch64" ] || [ "$arch_now" = "arm64" ]; then
        "$BIN_DIR/xui_install_box64.sh" || true
      fi
      "$BIN_DIR/xui_install_wine.sh" || true
    fi
}

write_logger_and_helpers(){
    info "write_logger_and_helpers: creating simple logger helper"
    cat > "$BIN_DIR/xui_log.sh" <<'SH' || true
#!/usr/bin/env bash
echo "[XUI-LOG] $*"
SH
    chmod +x "$BIN_DIR/xui_log.sh" || true
}

write_backup_restore(){
    info "write_backup_restore: no-op"
    return 0
}

write_diagnostics(){
    info "write_diagnostics: no-op"
    return 0
}

write_profiles_manager(){
    info "write_profiles_manager: no-op"
    return 0
}

write_plugins_skeleton(){
    info "write_plugins_skeleton: no-op"
    return 0
}

write_auto_update(){
    info "write_auto_update: no-op"
    return 0
}

write_uninstall(){
    info "write_uninstall: creating simple uninstall helper"
    cat > "$BIN_DIR/xui_uninstall.sh" <<'SH' || true
#!/usr/bin/env bash
echo "This will remove ~/.xui (dry-run). Run with --confirm to actually delete."
if [ "${1:-}" = "--confirm" ]; then
    rm -rf "$XUI_DIR" && echo "Removed $XUI_DIR"
fi
SH
    chmod +x "$BIN_DIR/xui_uninstall.sh" || true
}

write_readme_and_requirements(){
    info "write_readme_and_requirements: writing minimal README"
    cat > "$XUI_DIR/README.md" <<'MD' || true
# XUI (installed from single-file installer)
This directory was created by the xui installer. Assets and helper scripts live under ~/.xui
MD
}

write_basic_tests(){
    info "write_basic_tests: no-op"
    return 0
}


copy_assets(){
  # Copy common asset types from installer directory (script dir) into assets
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # First copy explicit common assets if present
    for name in applogo.png bootlogo.png startup.mp3 startup.mp4; do
        if [ -f "$script_dir/$name" ]; then
            cp -f "$script_dir/$name" "$ASSETS_DIR/" && info "Copied $name to assets"
        fi
    done

    # Copy tile images and other media files present in installer dir
    for ext in png jpg jpeg webp mp3 mp4; do
        for f in "$script_dir"/*.$ext; do
            [ -f "$f" ] || continue
            # avoid duplicating files already copied
            bn=$(basename "$f")
            case "$bn" in
                applogo.png|bootlogo.png|startup.mp3|startup.mp4) continue;;
            esac
            cp -f "$f" "$ASSETS_DIR/" && info "Copied $bn to assets"
        done
    done

    # Copy optional sounds from SONIDOS/user_sounds preserving names.
    if [ -d "$script_dir/SONIDOS" ] || [ -d "$script_dir/sonidos" ] || [ -d "$script_dir/user_sounds" ]; then
        mkdir -p "$ASSETS_DIR/SONIDOS"
        for d in "$script_dir/SONIDOS" "$script_dir/sonidos" "$script_dir/user_sounds"; do
            [ -d "$d" ] || continue
            find "$d" -type f \( -iname '*.mp3' -o -iname '*.wav' \) -print0 | while IFS= read -r -d '' f; do
                bn=$(basename "$f")
                cp -f "$f" "$ASSETS_DIR/SONIDOS/$bn" && info "Copied sound $bn to assets/SONIDOS"
                case "${bn,,}" in
                    startup.mp3) cp -f "$f" "$ASSETS_DIR/startup.mp3" || true ;;
                esac
            done
        done
    fi
}

generate_placeholders(){
    # Create placeholder images for essential assets if missing using Pillow
    if check_cmd python3; then
        python3 - <<'PY' || true
from pathlib import Path
try:
        from PIL import Image, ImageDraw, ImageFont
except Exception:
        Image = None
AS = Path.home()/'.xui'/'assets'
AS.mkdir(parents=True, exist_ok=True)
if Image is not None:
        def make_img(fn, size=(320,180), text='XUI'):
                p = AS/fn
                if p.exists():
                        return
                try:
                        im = Image.new('RGBA', size, (12,84,166,255))
                        d = ImageDraw.Draw(im)
                        try:
                                f = ImageFont.truetype('DejaVuSans-Bold.ttf', max(24, size[1]//6))
                        except Exception:
                                f = ImageFont.load_default()
                        w,h = d.textsize(text, font=f)
                        d.text(((size[0]-w)/2,(size[1]-h)/2), text, fill=(255,255,255,255), font=f)
                        im.save(p)
                except Exception:
                        pass
        make_img('applogo.png', (512,512), 'XUI')
        make_img('bootlogo.png', (800,450), 'XUI')
        tiles = ['Casino','Runner','Store','Misiones','Perfil','Compat X86','LAN','Power Profile','Battery Saver','Salir al escritorio']
        for t in tiles:
                make_img(f"{t}.png", (320,180), t)
PY
    else
        warn "python3 (Pillow) not available — cannot generate placeholder images"
    fi

    # Generate startup.mp3/mp4 via ffmpeg if missing
    if [ ! -f "$ASSETS_DIR/startup.mp3" ] && command -v ffmpeg >/dev/null 2>&1; then
        info "Generating startup.mp3 via ffmpeg"
        ffmpeg -y -f lavfi -i "sine=frequency=440:duration=3" -c:a libmp3lame -q:a 4 "$ASSETS_DIR/startup.mp3" >/dev/null 2>&1 || warn "ffmpeg failed to create startup.mp3"
    fi
    if [ ! -f "$ASSETS_DIR/startup.mp4" ] && command -v ffmpeg >/dev/null 2>&1 && [ -f "$ASSETS_DIR/applogo.png" ]; then
        info "Generating startup.mp4 from applogo.png via ffmpeg"
        ffmpeg -y -loop 1 -i "$ASSETS_DIR/applogo.png" -c:v libx264 -t 3 -pix_fmt yuv420p "$ASSETS_DIR/startup.mp4" >/dev/null 2>&1 || warn "ffmpeg failed to create startup.mp4"
    fi
}

copy_all_mp3s(){
    # Recursively copy any mp3 files from installer directory into assets
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    find "$script_dir" -type f -iname '*.mp3' -print0 | while IFS= read -r -d '' f; do
        bn=$(basename "$f")
        # skip startup if already copied
        if [ -f "$ASSETS_DIR/$bn" ]; then
            info "Skipping existing $bn"
            continue
        fi
        cp -f "$f" "$ASSETS_DIR/" && info "Copied mp3 $bn to assets"
    done
}

convert_pngs_to_webp(){
  if check_cmd cwebp; then
    for p in "$ASSETS_DIR"/*.png; do
      [ -f "$p" ] || continue
      out="${p%.png}.webp"
      cwebp -q 80 "$p" -o "$out" >/dev/null 2>&1 || true
    done
  elif check_cmd python3; then
    python3 - <<'PY' || true
from pathlib import Path
try:
    from PIL import Image
except Exception:
    Image = None
ad = Path.home()/'.xui'/'assets'
if Image is not None:
    for p in ad.glob('*.png'):
        try:
            img = Image.open(p)
            img.save(p.with_suffix('.webp'), 'WEBP', quality=80)
        except Exception:
            pass
PY
  else
    warn "No converter found for PNG->WEBP (install cwebp or Pillow)"
  fi
}

write_manifest(){
  if check_cmd python3; then
    python3 - <<'PY' || true
import os, json
ad = os.path.expanduser('~/.xui/assets')
files = sorted([f for f in os.listdir(ad) if not f.startswith('.')])
out={'assets': files}
with open(os.path.join(ad,'manifest.json'),'w') as fh:
    json.dump(out, fh, indent=2)
print('manifest_written')
PY
    info "Wrote $ASSETS_DIR/manifest.json"
  else
    warn "python3 not found; skipping manifest generation"
  fi
}

write_dashboard_py(){
  cat > "$DASH_DIR/pyqt_dashboard_improved.py" <<'PY'
#!/usr/bin/env python3
import sys
import json
import subprocess
import shutil
import os
import time
import shlex
import queue
import socket
import threading
import uuid
from pathlib import Path
from PyQt5 import QtWidgets, QtGui, QtCore
try:
    from PyQt5 import QtWebEngineWidgets
except Exception:
    QtWebEngineWidgets = None

ASSETS = Path.home() / '.xui' / 'assets'
XUI_HOME = Path.home() / '.xui'
DATA_HOME = XUI_HOME / 'data'
RECENT_FILE = DATA_HOME / 'recent.json'
FRIENDS_FILE = DATA_HOME / 'friends.json'
PROFILE_FILE = DATA_HOME / 'profile.json'
PEERS_FILE = DATA_HOME / 'social_peers.json'


def play_media(path, video=False, blocking=False):
    p = Path(path)
    if not p.exists():
        return False
    try:
        if shutil.which('mpv'):
            cmd = ['mpv', '--really-quiet', '--no-terminal']
            if video:
                cmd.extend(['--fullscreen', '--ontop'])
            else:
                cmd.append('--no-video')
            cmd.append(str(p))
            if blocking:
                subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            else:
                subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
    except Exception:
        pass
    return False


def play_startup_video():
    if os.environ.get('XUI_SKIP_STARTUP_VIDEO', '0') == '1':
        return
    play_media(ASSETS / 'startup.mp4', video=True, blocking=True)


def ensure_data():
    DATA_HOME.mkdir(parents=True, exist_ok=True)
    if not RECENT_FILE.exists():
        RECENT_FILE.write_text('[]')
    if not FRIENDS_FILE.exists():
        FRIENDS_FILE.write_text(json.dumps([
            {'name': 'Friend1', 'online': True},
            {'name': 'Friend2', 'online': False}
        ], indent=2))
    if not PROFILE_FILE.exists():
        PROFILE_FILE.write_text(json.dumps({'gamertag': 'Player1', 'signed_in': False}, indent=2))


def pick_existing_sound(candidates):
    if not candidates:
        return None
    search_dirs = [
        ASSETS / 'SONIDOS',
        ASSETS / 'sonidos',
        XUI_HOME / 'SONIDOS',
        XUI_HOME / 'sonidos',
        XUI_HOME / 'user_sounds',
        ASSETS,
    ]
    for fn in candidates:
        if not fn:
            continue
        for d in search_dirs:
            p = d / fn
            if p.exists():
                return p
    return None


def safe_json_read(path, default):
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except Exception:
        return default


def safe_json_write(path, data):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding='utf-8')


def current_gamertag():
    p = safe_json_read(PROFILE_FILE, {})
    name = str(p.get('gamertag', 'Player1')).strip()
    return name or 'Player1'


def local_ipv4_addresses():
    ips = set()
    try:
        for ip in subprocess.getoutput('hostname -I 2>/dev/null').split():
            if ip and not ip.startswith('127.'):
                ips.add(ip)
    except Exception:
        pass
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('1.1.1.1', 80))
        ip = s.getsockname()[0]
        s.close()
        if ip and not ip.startswith('127.'):
            ips.add(ip)
    except Exception:
        pass
    return sorted(ips) if ips else ['127.0.0.1']


def local_ipv4_broadcasts():
    targets = set()
    try:
        out = subprocess.getoutput('ip -o -4 addr show scope global 2>/dev/null')
        for line in out.splitlines():
            parts = line.split()
            if 'brd' in parts:
                idx = parts.index('brd')
                if idx + 1 < len(parts):
                    brd = parts[idx + 1].strip()
                    if brd and not brd.startswith('127.'):
                        targets.add(brd)
    except Exception:
        pass
    return sorted(targets)


def parse_peer_id(text):
    raw = str(text or '').strip()
    if not raw:
        return None
    alias = ''
    if '@' in raw:
        alias, raw = raw.split('@', 1)
    if ':' not in raw:
        return None
    host, port_s = raw.rsplit(':', 1)
    host = host.strip()
    try:
        port = int(port_s.strip())
    except Exception:
        return None
    if not host or port < 1 or port > 65535:
        return None
    return {
        'name': alias.strip() or host,
        'host': host,
        'port': int(port),
        'source': 'manual',
    }


class InlineSocialEngine:
    def __init__(self, nickname, chat_base=38600, discovery_port=38655):
        self.nickname = nickname
        self.node_id = uuid.uuid4().hex[:12]
        self.chat_port = self._find_open_port(chat_base, 24)
        self.discovery_port = int(discovery_port)
        self.events = queue.Queue()
        self.running = False
        self.threads = []
        self.peers = {}
        self.lock = threading.Lock()
        self.local_ips = set(local_ipv4_addresses())

    def _find_open_port(self, base, span):
        for port in range(int(base), int(base) + int(span)):
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                s.bind(('', port))
                s.close()
                return int(port)
            except OSError:
                s.close()
                continue
        return 0

    def start(self):
        self.running = True
        for fn in (self._tcp_server_loop, self._udp_discovery_listener, self._udp_discovery_sender, self._peer_gc_loop):
            t = threading.Thread(target=fn, daemon=True)
            self.threads.append(t)
            t.start()
        if self.chat_port:
            self.events.put(('status', f'Chat TCP listening on port {self.chat_port}'))
        else:
            self.events.put(('status', 'No free TCP chat port available'))

    def stop(self):
        self.running = False
        for t in self.threads:
            t.join(timeout=0.2)

    def send_chat(self, host, port, text):
        payload = {
            'type': 'chat',
            'node_id': self.node_id,
            'from': self.nickname,
            'text': str(text),
            'ts': time.time(),
            'reply_port': int(self.chat_port or 0),
        }
        body = (json.dumps(payload, ensure_ascii=False) + '\n').encode('utf-8', errors='ignore')
        with socket.create_connection((str(host), int(port)), timeout=4.0) as s:
            s.sendall(body)

    def _peer_key(self, host, port):
        return f'{host}:{int(port)}'

    def _is_local_host(self, host):
        h = str(host or '').strip()
        if not h:
            return False
        return h.startswith('127.') or h in self.local_ips

    def _upsert_peer(self, name, host, port, source='LAN', node_id=''):
        if not host or not port:
            return
        key = self._peer_key(host, port)
        now = time.time()
        data = {
            'name': name or host,
            'host': str(host),
            'port': int(port),
            'source': source,
            'node_id': str(node_id or ''),
            'last_seen': now,
        }
        changed = False
        with self.lock:
            prev = self.peers.get(key)
            if prev is None:
                changed = True
            elif prev.get('name') != data['name'] or prev.get('node_id') != data['node_id']:
                changed = True
            self.peers[key] = data
        if changed:
            self.events.put(('peer_up', key, data))

    def _peer_gc_loop(self):
        while self.running:
            time.sleep(2.0)
            now = time.time()
            removed = []
            with self.lock:
                for key, peer in list(self.peers.items()):
                    if peer.get('source') == 'LAN' and (now - float(peer.get('last_seen', 0.0))) > 10.0:
                        self.peers.pop(key, None)
                        removed.append(key)
            for key in removed:
                self.events.put(('peer_down', key))

    def _discovery_targets(self):
        out = [('255.255.255.255', self.discovery_port)]
        seen = {out[0]}
        for brd in local_ipv4_broadcasts():
            target = (str(brd), self.discovery_port)
            if target not in seen:
                seen.add(target)
                out.append(target)
        return out

    def _announce_packet(self):
        return {
            'type': 'announce',
            'node_id': self.node_id,
            'name': self.nickname,
            'chat_port': int(self.chat_port or 0),
            'reply_port': int(self.discovery_port),
            'ts': time.time(),
        }

    def _probe_packet(self):
        return {
            'type': 'probe',
            'node_id': self.node_id,
            'name': self.nickname,
            'chat_port': int(self.chat_port or 0),
            'reply_port': int(self.discovery_port),
            'ts': time.time(),
        }

    def _udp_discovery_sender(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        targets = self._discovery_targets()
        ticks = 0
        self.events.put(('status', f'LAN autodiscovery active on UDP {self.discovery_port}'))
        while self.running:
            if ticks % 8 == 0:
                targets = self._discovery_targets()
            packets = [self._announce_packet()]
            if ticks % 2 == 0:
                packets.insert(0, self._probe_packet())
            for pkt in packets:
                raw = json.dumps(pkt).encode('utf-8', errors='ignore')
                for target in targets:
                    try:
                        sock.sendto(raw, target)
                    except Exception:
                        pass
            time.sleep(2.5)
            ticks += 1
        sock.close()

    def _udp_discovery_listener(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(('', self.discovery_port))
        except OSError:
            self.events.put(('status', f'Cannot bind UDP discovery port {self.discovery_port}'))
            sock.close()
            return
        sock.settimeout(1.0)
        while self.running:
            try:
                raw, addr = sock.recvfrom(4096)
            except socket.timeout:
                continue
            except Exception:
                continue
            host = addr[0]
            if self._is_local_host(host):
                continue
            try:
                pkt = json.loads(raw.decode('utf-8', errors='ignore'))
            except Exception:
                continue
            remote_node = str(pkt.get('node_id') or '')
            if remote_node == self.node_id:
                continue
            ptype = str(pkt.get('type') or '')
            try:
                port = int(pkt.get('chat_port') or 0)
            except Exception:
                port = 0
            name = str(pkt.get('name') or host)
            if ptype == 'probe':
                reply = self._announce_packet()
                try:
                    sock.sendto(json.dumps(reply).encode('utf-8', errors='ignore'), (host, self.discovery_port))
                except Exception:
                    pass
                if port > 0:
                    self._upsert_peer(name, host, port, 'LAN', remote_node)
                continue
            if ptype != 'announce':
                continue
            if port <= 0:
                continue
            self._upsert_peer(name, host, port, 'LAN', remote_node)
        sock.close()

    def _tcp_server_loop(self):
        if not self.chat_port:
            return
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            srv.bind(('', self.chat_port))
            srv.listen(16)
        except OSError:
            self.events.put(('status', f'Cannot bind TCP chat port {self.chat_port}'))
            self.chat_port = 0
            srv.close()
            return
        srv.settimeout(1.0)
        while self.running:
            try:
                conn, addr = srv.accept()
            except socket.timeout:
                continue
            except Exception:
                continue
            host = addr[0]
            with conn:
                try:
                    data = conn.recv(65536).decode('utf-8', errors='ignore')
                except Exception:
                    data = ''
            if not data.strip():
                continue
            for line in data.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except Exception:
                    continue
                if msg.get('type') != 'chat':
                    continue
                sender = str(msg.get('from') or host)
                text = str(msg.get('text') or '').strip()
                sender_node = str(msg.get('node_id') or '')
                try:
                    reply_port = int(msg.get('reply_port') or 0)
                except Exception:
                    reply_port = 0
                if reply_port > 0:
                    self._upsert_peer(sender, host, reply_port, 'LAN', sender_node)
                if text:
                    self.events.put(('chat', sender, text))
        srv.close()


class SocialOverlay(QtWidgets.QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.nickname = current_gamertag()
        self.engine = InlineSocialEngine(self.nickname)
        self.peer_items = {}
        self.peer_data = {}
        self.setModal(True)
        self.setWindowFlags(QtCore.Qt.Dialog | QtCore.Qt.FramelessWindowHint)
        self.setAttribute(QtCore.Qt.WA_TranslucentBackground, True)
        self._build()
        self._load_manual_peers()
        self.engine.start()
        self.timer = QtCore.QTimer(self)
        self.timer.timeout.connect(self._poll_events)
        self.timer.start(120)
        self._append_system('LAN autodiscovery enabled (broadcast + probe). Add peer for Internet P2P.')

    def _build(self):
        self.setStyleSheet('''
            QFrame#social_panel {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #0f151c, stop:1 #1c2632);
                border:2px solid rgba(139,198,255,0.33);
                border-radius:8px;
            }
            QLabel#social_title { color:#f3f7f7; font-size:30px; font-weight:800; }
            QLabel#social_hint { color:rgba(237,243,247,0.75); font-size:16px; }
            QListWidget { background:#08111b; border:1px solid #2c3a4a; color:#e7eff5; font-size:17px; }
            QPlainTextEdit { background:#07101a; border:1px solid #2c3a4a; color:#e7eff5; font-size:17px; }
            QLineEdit { background:#0c1621; border:1px solid #2c3a4a; color:#eef5fa; font-size:18px; padding:7px; }
            QPushButton {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #34d85a, stop:1 #20b540);
                color:#efffee; border:1px solid rgba(255,255,255,0.2); font-size:17px; font-weight:700; padding:8px 12px;
            }
            QPushButton:hover { background:#42e666; }
        ''')
        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        panel = QtWidgets.QFrame()
        panel.setObjectName('social_panel')
        outer.addWidget(panel)
        root = QtWidgets.QVBoxLayout(panel)
        root.setContentsMargins(16, 14, 16, 12)
        root.setSpacing(10)

        top = QtWidgets.QHBoxLayout()
        title = QtWidgets.QLabel('social / messages')
        title.setObjectName('social_title')
        hint = QtWidgets.QLabel(f'gamertag: {self.nickname}')
        hint.setObjectName('social_hint')
        btn_close = QtWidgets.QPushButton('Close (ESC)')
        btn_close.clicked.connect(self.reject)
        top.addWidget(title)
        top.addStretch(1)
        top.addWidget(hint)
        top.addSpacing(14)
        top.addWidget(btn_close)
        root.addLayout(top)

        body = QtWidgets.QHBoxLayout()
        left = QtWidgets.QVBoxLayout()
        left_lbl = QtWidgets.QLabel('Peers (LAN / P2P)')
        left_lbl.setStyleSheet('font-size:24px; font-weight:700; color:#f4f8fa;')
        self.peers = QtWidgets.QListWidget()
        self.peers.setMinimumWidth(360)
        self.btn_add = QtWidgets.QPushButton('Add Peer ID')
        self.btn_ids = QtWidgets.QPushButton('My Peer IDs')
        self.btn_lan = QtWidgets.QPushButton('LAN Status')
        self.btn_add.clicked.connect(self._add_peer)
        self.btn_ids.clicked.connect(self._show_peer_ids)
        self.btn_lan.clicked.connect(self._show_lan_status)
        left.addWidget(left_lbl)
        left.addWidget(self.peers, 1)
        left.addWidget(self.btn_add)
        left.addWidget(self.btn_ids)
        left.addWidget(self.btn_lan)

        right = QtWidgets.QVBoxLayout()
        self.chat = QtWidgets.QPlainTextEdit()
        self.chat.setReadOnly(True)
        self.input = QtWidgets.QLineEdit()
        self.input.setPlaceholderText('Write a message...')
        self.btn_send = QtWidgets.QPushButton('Send')
        self.btn_send.clicked.connect(self._send_current)
        self.input.returnPressed.connect(self._send_current)
        send_row = QtWidgets.QHBoxLayout()
        send_row.addWidget(self.input, 1)
        send_row.addWidget(self.btn_send)
        self.status = QtWidgets.QLabel('Ready')
        self.status.setObjectName('social_hint')
        right.addWidget(self.chat, 1)
        right.addLayout(send_row)
        right.addWidget(self.status)

        body.addLayout(left)
        body.addLayout(right, 1)
        root.addLayout(body, 1)
        bottom = QtWidgets.QLabel('ENTER = send | ESC/BACK = close | Use peer format alias@host:port')
        bottom.setObjectName('social_hint')
        root.addWidget(bottom)

    def showEvent(self, e):
        super().showEvent(e)
        parent = self.parentWidget()
        if parent is None:
            return
        pw = parent.width()
        ph = parent.height()
        w = max(980, int(pw * 0.84))
        h = max(560, int(ph * 0.74))
        self.resize(min(w, pw - 80), min(h, ph - 80))
        x = parent.x() + (pw - self.width()) // 2
        y = parent.y() + (ph - self.height()) // 2
        self.move(max(0, x), max(0, y))

    def keyPressEvent(self, e):
        if e.key() in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.reject()
            return
        super().keyPressEvent(e)

    def _append_line(self, text):
        self.chat.appendPlainText(text)
        sb = self.chat.verticalScrollBar()
        sb.setValue(sb.maximum())

    def _append_system(self, text):
        self._append_line(f"[{time.strftime('%H:%M:%S')}] [SYSTEM] {text}")

    def _append_chat(self, who, text):
        self._append_line(f"[{time.strftime('%H:%M:%S')}] {who}: {text}")

    def _peer_row(self, peer):
        return f"{peer['name']}  [{peer['host']}:{peer['port']}]  ({peer['source']})"

    def _upsert_peer(self, peer, persist=False):
        key = f"{peer['host']}:{int(peer['port'])}"
        data = {
            'name': str(peer.get('name') or peer.get('host')),
            'host': str(peer.get('host')),
            'port': int(peer.get('port') or 0),
            'source': str(peer.get('source') or 'LAN'),
            'node_id': str(peer.get('node_id') or ''),
        }
        if data['port'] <= 0 or not data['host']:
            return
        if key in self.peer_items:
            self.peer_data[key].update(data)
            self.peer_items[key].setText(self._peer_row(self.peer_data[key]))
        else:
            it = QtWidgets.QListWidgetItem(self._peer_row(data))
            it.setData(QtCore.Qt.UserRole, key)
            self.peers.addItem(it)
            self.peer_items[key] = it
            self.peer_data[key] = data
            if self.peers.currentRow() < 0:
                self.peers.setCurrentRow(0)
        if persist:
            self._save_manual_peers()

    def _remove_peer(self, key):
        it = self.peer_items.pop(key, None)
        self.peer_data.pop(key, None)
        if it is None:
            return
        row = self.peers.row(it)
        if row >= 0:
            self.peers.takeItem(row)

    def _selected_peer(self):
        it = self.peers.currentItem()
        if not it:
            return None
        key = it.data(QtCore.Qt.UserRole)
        return self.peer_data.get(key)

    def _host_priority(self, host):
        h = str(host or '')
        if h.startswith('127.'):
            return 30
        if h.startswith('10.0.2.'):
            # VirtualBox NAT default, often not valid between different VMs.
            return 20
        return 0

    def _send_candidates(self, peer):
        selected_host = str(peer.get('host') or '')
        selected_port = int(peer.get('port') or 0)
        selected_name = str(peer.get('name') or '').strip().lower()
        selected_node = str(peer.get('node_id') or '')
        weighted = []
        for key, p in self.peer_data.items():
            host = str(p.get('host') or '')
            try:
                port = int(p.get('port') or 0)
            except Exception:
                port = 0
            if not host or port <= 0:
                continue
            src = str(p.get('source') or '')
            name = str(p.get('name') or '').strip().lower()
            node = str(p.get('node_id') or '')
            rank = 9
            if host == selected_host and port == selected_port:
                rank = 0
            elif selected_node and node and node == selected_node:
                rank = 1
            elif host == selected_host:
                rank = 2
            elif src == 'LAN' and selected_name and name == selected_name:
                rank = 3
            weighted.append((rank, self._host_priority(host), host, port, key))
        weighted.sort(key=lambda x: (x[0], x[1], x[2], x[3]))
        out = []
        seen = set()
        for _rank, _hp, host, port, key in weighted:
            endpoint = (host, int(port))
            if endpoint in seen:
                continue
            seen.add(endpoint)
            out.append((host, int(port), key))
        return out

    def _save_manual_peers(self):
        arr = []
        for p in self.peer_data.values():
            if p.get('source') == 'manual':
                arr.append({'name': p.get('name'), 'host': p.get('host'), 'port': int(p.get('port') or 0)})
        safe_json_write(PEERS_FILE, {'manual_peers': arr})

    def _load_manual_peers(self):
        data = safe_json_read(PEERS_FILE, {'manual_peers': []})
        for p in data.get('manual_peers', []):
            try:
                self._upsert_peer({
                    'name': p.get('name') or p.get('host'),
                    'host': p.get('host'),
                    'port': int(p.get('port') or 0),
                    'source': 'manual',
                }, persist=False)
            except Exception:
                continue

    def _add_peer(self):
        d = EscInputDialog(self)
        d.setWindowTitle('Add P2P peer')
        d.setLabelText('Format: alias@host:port or host:port')
        d.setInputMode(QtWidgets.QInputDialog.TextInput)
        if d.exec_() != QtWidgets.QDialog.Accepted:
            return
        parsed = parse_peer_id(d.textValue())
        if not parsed:
            QtWidgets.QMessageBox.warning(self, 'Invalid peer', 'Use alias@host:port or host:port')
            return
        self._upsert_peer(parsed, persist=True)
        self._append_system(f"Manual peer added: {parsed['host']}:{parsed['port']}")

    def _show_peer_ids(self):
        ips = local_ipv4_addresses()
        lines = [f'{ip}:{self.engine.chat_port}' for ip in ips]
        if not self.engine.chat_port:
            lines += ['', 'Warning: chat TCP server is not active on this dashboard.']
        if ips and all(str(ip).startswith('10.0.2.') for ip in ips):
            lines += ['', 'VirtualBox NAT detected (10.0.2.x only).', 'Use Bridged or Host-Only Adapter for VM-to-VM LAN chat.']
        QtWidgets.QMessageBox.information(self, 'My Peer IDs', '\n'.join(lines))

    def _show_lan_status(self):
        out = subprocess.getoutput('ip -brief -4 addr 2>/dev/null || ip -4 addr show 2>/dev/null || true')
        QtWidgets.QMessageBox.information(self, 'LAN Status', out or 'No network data.')

    def _send_current(self):
        peer = self._selected_peer()
        if not peer:
            QtWidgets.QMessageBox.information(self, 'Peer required', 'Select a peer first.')
            return
        txt = self.input.text().strip()
        if not txt:
            return
        last_err = None
        used = None
        candidates = self._send_candidates(peer)
        for host, port, key in candidates:
            try:
                self.engine.send_chat(host, port, txt)
                used = (host, int(port), key)
                break
            except Exception as e:
                last_err = e
                continue
        if used:
            host, port, key = used
            self._append_chat(f"You -> {peer['name']}", txt)
            if host == str(peer.get('host')) and int(port) == int(peer.get('port') or 0):
                self.status.setText(f"Sent to {host}:{port}")
            else:
                self.status.setText(f"Sent via fallback {host}:{port}")
                item = self.peer_items.get(key)
                if item is not None:
                    self.peers.setCurrentItem(item)
            self.input.clear()
            return
        err_txt = str(last_err) if last_err is not None else 'No reachable peer endpoint.'
        self.status.setText(f'Cannot send: {err_txt}')

    def _poll_events(self):
        while True:
            try:
                evt = self.engine.events.get_nowait()
            except queue.Empty:
                break
            kind = evt[0]
            if kind == 'status':
                self.status.setText(str(evt[1]))
            elif kind == 'peer_up':
                _kind, _key, data = evt
                self._upsert_peer(data, persist=False)
            elif kind == 'peer_down':
                _kind, key = evt
                peer = self.peer_data.get(key)
                if peer and peer.get('source') == 'LAN':
                    self._remove_peer(key)
            elif kind == 'chat':
                _kind, sender, text = evt
                self._append_chat(sender, text)

    def closeEvent(self, e):
        try:
            self.timer.stop()
        except Exception:
            pass
        self.engine.stop()
        super().closeEvent(e)


class TabLabel(QtWidgets.QLabel):
    clicked = QtCore.pyqtSignal()

    def mousePressEvent(self, e):
        self.clicked.emit()
        super().mousePressEvent(e)


class TopTabs(QtWidgets.QWidget):
    changed = QtCore.pyqtSignal(int)

    def __init__(self, names, parent=None):
        super().__init__(parent)
        self.names = list(names)
        self.labels = []
        self.current = 0
        h = QtWidgets.QHBoxLayout(self)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(28)
        for i, n in enumerate(self.names):
            lbl = TabLabel(n)
            lbl.setCursor(QtGui.QCursor(QtCore.Qt.PointingHandCursor))
            lbl.clicked.connect(lambda i=i: self.changed.emit(i))
            self.labels.append(lbl)
            h.addWidget(lbl)
        h.addStretch(1)
        self.set_current(0)

    def set_current(self, idx):
        self.current = max(0, min(idx, len(self.labels)-1))
        for i, lbl in enumerate(self.labels):
            if i == self.current:
                lbl.setStyleSheet('color:#f3f7f7; font-size:56px; font-weight:700;')
            else:
                lbl.setStyleSheet('color:rgba(243,247,247,0.78); font-size:48px; font-weight:600;')


def tile_icon(action, text=''):
    key = f'{action} {text}'.lower()
    style = QtWidgets.QApplication.style()

    def themed(names, fallback):
        for name in names:
            icon = QtGui.QIcon.fromTheme(name)
            if not icon.isNull():
                return icon
        return style.standardIcon(fallback)

    if any(token in key for token in ('steam', 'retroarch', 'lutris', 'heroic', 'runner', 'casino', 'mission', 'game')):
        return themed(['steam', 'applications-games', 'input-gaming'], QtWidgets.QStyle.SP_MediaPlay)
    if any(token in key for token in ('store', 'avatar')):
        return themed(['folder-downloads', 'applications-other'], QtWidgets.QStyle.SP_DirIcon)
    if any(token in key for token in ('music', 'audio', 'playlist', 'visualizer', 'startup sound')):
        return themed(['audio-x-generic', 'multimedia-volume-control'], QtWidgets.QStyle.SP_MediaVolume)
    if any(token in key for token in ('tv', 'movie', 'media', 'youtube', 'netflix', 'kodi', 'video')):
        return themed(['video-x-generic', 'applications-multimedia'], QtWidgets.QStyle.SP_MediaPlay)
    if any(token in key for token in ('social', 'friend', 'message', 'party', 'gamer')):
        return themed(['user-available', 'im-user-online'], QtWidgets.QStyle.SP_DirHomeIcon)
    if any(token in key for token in ('settings', 'system', 'service', 'developer', 'battery', 'power', 'profile')):
        return themed(['preferences-system', 'applications-system'], QtWidgets.QStyle.SP_ComputerIcon)
    if any(token in key for token in ('web', 'browser', 'network', 'lan')):
        return themed(['internet-web-browser', 'network-workgroup'], QtWidgets.QStyle.SP_DriveNetIcon)
    if any(token in key for token in ('turn off', 'exit', 'shutdown')):
        return themed(['system-shutdown', 'application-exit'], QtWidgets.QStyle.SP_TitleBarCloseButton)
    return themed(['applications-other'], QtWidgets.QStyle.SP_FileIcon)


class GreenTile(QtWidgets.QFrame):
    clicked = QtCore.pyqtSignal(str)

    def __init__(self, action, text, size=(250, 140), parent=None):
        super().__init__(parent)
        self.action = action
        self.text = text
        self.setFixedSize(*size)
        self.setObjectName('green_tile')
        self.setFocusPolicy(QtCore.Qt.StrongFocus)
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(16, 12, 16, 12)
        top = QtWidgets.QHBoxLayout()
        top.setContentsMargins(0, 0, 0, 0)
        self.icon = QtWidgets.QLabel()
        self.icon.setObjectName('tile_icon')
        self.icon.setFixedSize(44, 44)
        self.icon.setAlignment(QtCore.Qt.AlignCenter)
        icon = tile_icon(action, text)
        self.icon.setPixmap(icon.pixmap(26, 26))
        top.addWidget(self.icon, 0, alignment=QtCore.Qt.AlignLeft | QtCore.Qt.AlignTop)
        top.addStretch(1)
        v.addLayout(top)
        v.addStretch(1)
        self.lbl = QtWidgets.QLabel(text)
        self.lbl.setStyleSheet('color:#efffee; font-size:30px; font-weight:700;')
        v.addWidget(self.lbl, alignment=QtCore.Qt.AlignLeft | QtCore.Qt.AlignBottom)
        self.set_selected(False)

    def set_selected(self, on):
        border = '#c6ffff' if on else 'rgba(255,255,255,0.08)'
        width = '4px' if on else '1px'
        self.setStyleSheet(f'''
            QFrame#green_tile {{
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #34d85a, stop:1 #20b540);
                border:{width} solid {border};
                border-radius:4px;
            }}
            QLabel#tile_icon {{
                background:rgba(0,0,0,0.18);
                border:1px solid rgba(255,255,255,0.22);
                border-radius:8px;
            }}
            QLabel{{color:#efffee;}}
        ''')

    def mousePressEvent(self, e):
        self.clicked.emit(self.action)
        super().mousePressEvent(e)


class HeroPanel(QtWidgets.QFrame):
    clicked = QtCore.pyqtSignal(str)

    def __init__(self, action='Hub', title='home', subtitle='featured', parent=None):
        super().__init__(parent)
        self.action = action
        self.title = title
        self.subtitle = subtitle
        self.setFixedSize(900, 460)
        self.setObjectName('hero_panel')
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(22, 18, 22, 16)
        top = QtWidgets.QLabel(self.title)
        top.setStyleSheet('color:#ecf3f5; font-size:38px; font-weight:700;')
        v.addWidget(top, 0, alignment=QtCore.Qt.AlignLeft | QtCore.Qt.AlignTop)
        v.addStretch(1)
        sub = QtWidgets.QLabel(self.subtitle)
        sub.setStyleSheet('color:rgba(235,242,244,0.78); font-size:24px; font-weight:600;')
        v.addWidget(sub, 0, alignment=QtCore.Qt.AlignLeft | QtCore.Qt.AlignBottom)
        self.set_selected(False)

    def set_selected(self, on):
        border = '#c6ffff' if on else 'rgba(255,255,255,0.08)'
        width = '4px' if on else '1px'
        self.setStyleSheet(f'''
            QFrame#hero_panel {{
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #121518, stop:1 #1f262c);
                border:{width} solid {border};
                border-radius:4px;
            }}
        ''')

    def mousePressEvent(self, e):
        self.clicked.emit(self.action)
        super().mousePressEvent(e)


class QuickMenu(QtWidgets.QDialog):
    def __init__(self, title, options, descriptions=None, parent=None):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.setWindowFlags(QtCore.Qt.Dialog | QtCore.Qt.FramelessWindowHint)
        self.setAttribute(QtCore.Qt.WA_TranslucentBackground, True)
        self.setModal(True)
        self.descriptions = descriptions or {}
        self.resize(760, 500)
        self.setStyleSheet('''
            QFrame#guide_panel {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #0e141b, stop:1 #1e2732);
                border:2px solid rgba(161,214,255,0.42);
                border-radius:8px;
            }
            QLabel#guide_title { color:#f2f7f9; font-size:34px; font-weight:800; }
            QLabel#guide_hint { color:rgba(241,247,251,0.76); font-size:16px; }
            QFrame#guide_left {
                background:rgba(7,16,28,0.82);
                border:1px solid rgba(128,170,205,0.25);
            }
            QFrame#guide_info {
                background:rgba(176,183,191,0.26);
                border:1px solid rgba(200,208,216,0.33);
            }
            QLabel#guide_info_title {
                color:#f2f6f8;
                font-size:19px;
                font-weight:700;
            }
            QLabel#guide_info_text {
                color:rgba(239,244,247,0.9);
                font-size:15px;
            }
            QListWidget {
                background:#08111b;
                color:#f3f7f7;
                font-size:26px;
                border:1px solid #39506a;
                outline:none;
            }
            QListWidget::item {
                padding:8px 10px;
                border:1px solid transparent;
            }
            QListWidget::item:selected {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #34d85a, stop:1 #20b540);
                color:#efffee;
                border:1px solid rgba(255,255,255,0.22);
            }
        ''')
        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        panel = QtWidgets.QFrame()
        panel.setObjectName('guide_panel')
        outer.addWidget(panel)
        v = QtWidgets.QVBoxLayout(panel)
        v.setContentsMargins(14, 12, 14, 10)
        v.setSpacing(8)
        t = QtWidgets.QLabel(title)
        t.setObjectName('guide_title')
        v.addWidget(t)
        body = QtWidgets.QHBoxLayout()
        body.setSpacing(12)
        left = QtWidgets.QFrame()
        left.setObjectName('guide_left')
        left_l = QtWidgets.QVBoxLayout(left)
        left_l.setContentsMargins(8, 8, 8, 8)
        left_l.setSpacing(6)
        self.listw = QtWidgets.QListWidget()
        self.listw.addItems(options)
        self.listw.setCurrentRow(0)
        self.listw.itemDoubleClicked.connect(lambda *_: self.accept())
        left_l.addWidget(self.listw, 1)
        self.listw.itemActivated.connect(lambda *_: self.accept())
        body.addWidget(left, 3)
        info = QtWidgets.QFrame()
        info.setObjectName('guide_info')
        info.setMinimumWidth(280)
        info_l = QtWidgets.QVBoxLayout(info)
        info_l.setContentsMargins(12, 10, 12, 10)
        info_l.setSpacing(6)
        info_t = QtWidgets.QLabel('Details')
        info_t.setObjectName('guide_info_title')
        self.info_text = QtWidgets.QLabel('')
        self.info_text.setWordWrap(True)
        self.info_text.setObjectName('guide_info_text')
        info_l.addWidget(info_t)
        info_l.addWidget(self.info_text, 1)
        body.addWidget(info, 2)
        v.addLayout(body, 1)
        self.listw.currentTextChanged.connect(self._update_description)
        self._update_description(self.selected() or '')
        hint = QtWidgets.QLabel('ESC = Back | ENTER = Select')
        hint.setObjectName('guide_hint')
        v.addWidget(hint)

    def showEvent(self, e):
        super().showEvent(e)
        parent = self.parentWidget()
        if parent is None:
            return
        # Xbox-360 style: centered guide panel inside dashboard.
        w = min(max(900, int(parent.width() * 0.74)), max(900, parent.width() - 80))
        h = min(max(540, int(parent.height() * 0.72)), max(540, parent.height() - 80))
        self.resize(w, h)
        x = parent.x() + (parent.width() - w) // 2
        y = parent.y() + (parent.height() - h) // 2
        self.move(max(0, x), max(0, y))

    def selected(self):
        it = self.listw.currentItem()
        return it.text() if it else None

    def _update_description(self, item_text):
        txt = (self.descriptions or {}).get(item_text, '')
        if not txt:
            txt = f'Select "{item_text}" to open this option.'
        self.info_text.setText(txt)

    def keyPressEvent(self, e):
        if e.key() in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.reject()
            return
        super().keyPressEvent(e)


class EscInputDialog(QtWidgets.QInputDialog):
    def keyPressEvent(self, e):
        if e.key() in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.reject()
            return
        super().keyPressEvent(e)


class WebKioskWindow(QtWidgets.QMainWindow):
    def __init__(self, url, parent=None):
        super().__init__(parent)
        self.setWindowTitle(url)
        self.resize(1280, 720)
        self.setStyleSheet('background:#000;')
        self.view = QtWebEngineWidgets.QWebEngineView(self)
        self.setCentralWidget(self.view)
        self.view.load(QtCore.QUrl(url))
        self._esc = QtWidgets.QShortcut(QtGui.QKeySequence(QtCore.Qt.Key_Escape), self)
        self._esc.activated.connect(self.close)
        self._back = QtWidgets.QShortcut(QtGui.QKeySequence(QtCore.Qt.Key_Back), self)
        self._back.activated.connect(self.close)

    def keyPressEvent(self, e):
        if e.key() in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.close()
            return
        super().keyPressEvent(e)


class DashboardPage(QtWidgets.QWidget):
    actionTriggered = QtCore.pyqtSignal(str)

    def __init__(self, name, spec, parent=None):
        super().__init__(parent)
        self.name = name
        self.spec = spec
        self.left_tiles = []
        self.right_tiles = []
        self.hero = None
        self._build()

    def _build_tiles(self, defs, target, layout, alignment=QtCore.Qt.AlignLeft):
        for action, text, size in defs:
            tile = GreenTile(action, text, size)
            tile.clicked.connect(self.actionTriggered.emit)
            target.append(tile)
            layout.addWidget(tile, 0, alignment)

    def _build(self):
        body = QtWidgets.QHBoxLayout(self)
        body.setContentsMargins(0, 0, 0, 0)
        body.setSpacing(26)
        body.addStretch(1)

        left_col = QtWidgets.QWidget()
        left_col.setFixedWidth(320)
        left = QtWidgets.QVBoxLayout(left_col)
        left.setContentsMargins(0, 0, 0, 0)
        left.setSpacing(14)
        self._build_tiles(self.spec.get('left', []), self.left_tiles, left, QtCore.Qt.AlignLeft)
        left.addStretch(1)

        center_col = QtWidgets.QWidget()
        center = QtWidgets.QVBoxLayout(center_col)
        center.setContentsMargins(0, 0, 0, 0)
        center.setSpacing(14)
        self.hero = HeroPanel(
            self.spec.get('hero_action', 'Hub'),
            self.spec.get('hero_title', self.name),
            self.spec.get('hero_subtitle', 'featured'),
        )
        self.hero.clicked.connect(self.actionTriggered.emit)
        center.addWidget(self.hero, 0, alignment=QtCore.Qt.AlignHCenter)
        center.addStretch(1)

        right_col = QtWidgets.QWidget()
        right_col.setFixedWidth(320)
        right = QtWidgets.QVBoxLayout(right_col)
        right.setContentsMargins(0, 0, 0, 0)
        right.setSpacing(14)
        self._build_tiles(self.spec.get('right', []), self.right_tiles, right, QtCore.Qt.AlignRight)
        right.addStretch(1)

        body.addWidget(left_col, 0, alignment=QtCore.Qt.AlignVCenter)
        body.addWidget(center_col, 0, alignment=QtCore.Qt.AlignVCenter)
        body.addWidget(right_col, 0, alignment=QtCore.Qt.AlignVCenter)
        body.addStretch(1)


class Dashboard(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()
        ensure_data()
        self.setWindowTitle('XUI - Xbox 360 Style')
        self.resize(1600, 900)
        self.tabs = ['home', 'social', 'games', 'tv & movies', 'music', 'apps', 'settings']
        self.page_specs = {
            'home': {
                'hint': 'home: usa flechas para moverte y Enter para abrir',
                'hero_action': 'Hub',
                'hero_title': 'home',
                'hero_subtitle': 'featured',
                'left': [
                    ('Open Tray', 'Open Tray', (320, 170)),
                    ('My Pins', 'My Pins', (320, 170)),
                    ('Recent', 'Recent', (320, 205)),
                ],
                'right': [
                    ('Friends', 'Friends', (270, 130)),
                    ('Avatar Store', 'Avatar Store', (270, 130)),
                    ('Sign In', 'Sign In', (270, 130)),
                ],
            },
            'social': {
                'hint': 'social: amigos, chat LAN/P2P y comunidad',
                'hero_action': 'Social Hub',
                'hero_title': 'social',
                'hero_subtitle': 'friends and activity',
                'left': [
                    ('Friends', 'Friends', (320, 170)),
                    ('Messages', 'Messages', (320, 170)),
                    ('LAN Chat', 'LAN Chat', (320, 205)),
                ],
                'right': [
                    ('Gamer Card', 'Gamer Card', (270, 130)),
                    ('Social Apps', 'Social Apps', (270, 130)),
                    ('Sign In', 'Sign In', (270, 130)),
                ],
            },
            'games': {
                'hint': 'games: biblioteca y juego local',
                'hero_action': 'Games Hub',
                'hero_title': 'games',
                'hero_subtitle': 'play now',
                'left': [
                    ('Casino', 'Casino', (320, 170)),
                    ('Runner', 'Runner', (320, 170)),
                    ('Missions', 'Missions', (320, 205)),
                ],
                'right': [
                    ('Steam', 'Steam', (270, 130)),
                    ('RetroArch', 'RetroArch', (270, 130)),
                    ('Store', 'Store', (270, 130)),
                    ('Games Integrations', 'Integrations', (270, 130)),
                ],
            },
            'tv & movies': {
                'hint': 'tv & movies: video y streaming',
                'hero_action': 'Media Hub',
                'hero_title': 'tv & movies',
                'hero_subtitle': 'watch and stream',
                'left': [
                    ('Media Player', 'Media Player', (320, 170)),
                    ('Boot Video', 'Boot Video', (320, 170)),
                    ('System Info', 'System Info', (320, 205)),
                ],
                'right': [
                    ('Netflix', 'Netflix', (270, 130)),
                    ('YouTube', 'YouTube', (270, 130)),
                    ('Kodi', 'Kodi', (270, 130)),
                ],
            },
            'music': {
                'hint': 'music: audio del sistema y playlist',
                'hero_action': 'Music Hub',
                'hero_title': 'music',
                'hero_subtitle': 'listen',
                'left': [
                    ('Startup Sound', 'Startup Sound', (320, 170)),
                    ('All Audio Files', 'All Audio Files', (320, 170)),
                    ('Mute / Unmute', 'Mute / Unmute', (320, 205)),
                ],
                'right': [
                    ('Playlist', 'Playlist', (270, 130)),
                    ('Visualizer', 'Visualizer', (270, 130)),
                    ('System Music', 'System Music', (270, 130)),
                ],
            },
            'apps': {
                'hint': 'apps: utilidades, sistema y herramientas avanzadas',
                'hero_action': 'Apps Hub',
                'hero_title': 'apps',
                'hero_subtitle': 'tools, diagnostics and control',
                'left': [
                    ('Store', 'Store', (320, 170)),
                    ('Web Control', 'Web Control', (320, 170)),
                    ('Utilities', 'Utilities', (320, 205)),
                ],
                'right': [
                    ('App Launcher', 'App Launcher', (270, 130)),
                    ('Service Manager', 'Services', (270, 130)),
                    ('Developer Tools', 'Developer', (270, 130)),
                ],
            },
            'settings': {
                'hint': 'settings: sistema, energia y apagado',
                'hero_action': 'Settings Hub',
                'hero_title': 'settings',
                'hero_subtitle': 'system control',
                'left': [
                    ('System Info', 'System', (320, 170)),
                    ('Power Profile', 'Preferences', (320, 170)),
                    ('Battery Saver', 'Profile', (320, 205)),
                ],
                'right': [
                    ('Family', 'Family', (270, 130)),
                    ('Theme Toggle', 'Account', (270, 130)),
                    ('Battery Info', 'Battery', (270, 130)),
                    ('Setup Wizard', 'Setup', (270, 130)),
                    ('Turn Off', 'Turn Off', (270, 130)),
                ],
            },
        }
        self.tab_actions = {
            name: self._flatten_actions(spec)
            for name, spec in self.page_specs.items()
        }
        self.tab_idx = 0
        self.pages = []
        self.focus_memory = {i: ('center', 0) for i in range(len(self.tabs))}
        self.focus_area = 'center'
        self.focus_idx = 0
        self._last_focus_state = None
        self._last_hover_at = 0.0
        self._tab_animating = False
        self._tab_anim_group = None
        self._web_windows = []
        self.sfx = {
            'hover': 'hover.mp3',
            'open': 'open.mp3',
            'select': 'select.mp3',
            'back': 'back.mp3',
            'close': 'close.mp3',
            'achievement': 'archievements.mp3',
        }
        self.sfx_aliases = {
            'hover': ['hover.mp3', 'click.mp3'],
            'open': ['open.mp3', 'click.mp3'],
            'select': ['select.mp3', '10. Select A.mp3', 'click.mp3'],
            'back': ['back.mp3', '14. Back.mp3'],
            'close': ['close.mp3', '14. Back.mp3'],
            'achievement': ['archievements.mp3', 'achievement.mp3', 'select.mp3'],
        }
        self._build()
        self.update_focus()

    def _flatten_actions(self, spec):
        out = []
        seen = set()
        for action in [spec.get('hero_action', 'Hub')]:
            if action and action not in seen:
                seen.add(action)
                out.append(action)
        for group in ('left', 'right'):
            for action, _text, _size in spec.get(group, []):
                if action and action not in seen:
                    seen.add(action)
                    out.append(action)
        return out

    def _build(self):
        root = QtWidgets.QWidget()
        self.setCentralWidget(root)
        outer = QtWidgets.QVBoxLayout(root)
        outer.setContentsMargins(0, 0, 0, 0)

        stage = QtWidgets.QFrame()
        stage.setObjectName('stage')
        stage_l = QtWidgets.QVBoxLayout(stage)
        stage_l.setContentsMargins(150, 70, 150, 50)
        stage_l.setSpacing(18)

        self.top_tabs = TopTabs(self.tabs)
        self.top_tabs.changed.connect(self._on_tab_changed)
        stage_l.addWidget(self.top_tabs)

        self.page_stack = QtWidgets.QStackedWidget()
        sl = self.page_stack.layout()
        if isinstance(sl, QtWidgets.QStackedLayout):
            sl.setStackingMode(QtWidgets.QStackedLayout.StackAll)
        for tab_name in self.tabs:
            page = DashboardPage(tab_name, self.page_specs[tab_name], self)
            page.actionTriggered.connect(self.handle_action)
            self.pages.append(page)
            self.page_stack.addWidget(page)
        self.page_stack.setCurrentIndex(0)
        self._normalize_page_visibility(0)
        stage_l.addWidget(self.page_stack, 1)

        self.desc = QtWidgets.QLabel('Connect your device to the Internet to explore games, entertainment, and more')
        self.desc.setStyleSheet('font-size:28px; color:rgba(235,240,244,0.75);')
        stage_l.addWidget(self.desc)

        outer.addWidget(stage)

        self.setStyleSheet('''
            QMainWindow {
                background:qlineargradient(x1:0.5,y1:0.0,x2:0.5,y2:1.0, stop:0 #31353c, stop:0.58 #6f747c, stop:1 #d8dee4);
            }
            QFrame#stage {
                background: rgba(255,255,255,0.08);
                border-radius: 2px;
            }
        ''')

    def _current_page(self):
        return self.pages[self.tab_idx]

    def _normalize_page_visibility(self, idx=None):
        if idx is None:
            idx = self.page_stack.currentIndex()
        for i, page in enumerate(self.pages):
            page.move(0, 0)
            page.setVisible(i == idx)

    def _animate_tab_transition(self, from_idx, to_idx):
        if from_idx == to_idx:
            self.page_stack.setCurrentIndex(to_idx)
            self._normalize_page_visibility(to_idx)
            return
        if self._tab_animating:
            return
        from_w = self.page_stack.widget(from_idx)
        to_w = self.page_stack.widget(to_idx)
        rect = self.page_stack.rect()
        shift = rect.width() if to_idx > from_idx else -rect.width()

        for i, page in enumerate(self.pages):
            if i not in (from_idx, to_idx):
                page.hide()
        from_w.setGeometry(rect)
        to_w.setGeometry(rect)
        from_w.move(0, 0)
        to_w.move(shift, 0)
        from_w.show()
        to_w.show()
        to_w.raise_()

        self._tab_animating = True
        self._tab_anim_group = QtCore.QParallelAnimationGroup(self)

        anim_from = QtCore.QPropertyAnimation(from_w, b'pos')
        anim_from.setDuration(280)
        anim_from.setStartValue(QtCore.QPoint(0, 0))
        anim_from.setEndValue(QtCore.QPoint(-shift, 0))
        anim_from.setEasingCurve(QtCore.QEasingCurve.OutCubic)

        anim_to = QtCore.QPropertyAnimation(to_w, b'pos')
        anim_to.setDuration(280)
        anim_to.setStartValue(QtCore.QPoint(shift, 0))
        anim_to.setEndValue(QtCore.QPoint(0, 0))
        anim_to.setEasingCurve(QtCore.QEasingCurve.OutCubic)

        self._tab_anim_group.addAnimation(anim_from)
        self._tab_anim_group.addAnimation(anim_to)

        def done():
            self.page_stack.setCurrentIndex(to_idx)
            self._normalize_page_visibility(to_idx)
            self._tab_animating = False
            self.update_focus()

        self._tab_anim_group.finished.connect(done)
        self._tab_anim_group.start(QtCore.QAbstractAnimation.DeleteWhenStopped)

    def _switch_tab(self, idx, animate=True, keep_tabs_focus=False):
        idx = max(0, min(idx, len(self.tabs) - 1))
        if idx == self.tab_idx and self.page_stack.currentIndex() == idx:
            if keep_tabs_focus:
                self.focus_area = 'tabs'
                self.focus_idx = 0
            self.update_focus()
            return
        if self._tab_animating:
            return
        old_idx = self.tab_idx
        self.focus_memory[old_idx] = (self.focus_area, self.focus_idx)
        self.tab_idx = idx
        self.focus_area, self.focus_idx = self.focus_memory.get(idx, ('center', 0))
        if keep_tabs_focus:
            self.focus_area = 'tabs'
            self.focus_idx = 0
        if animate:
            self._animate_tab_transition(old_idx, idx)
        else:
            self.page_stack.setCurrentIndex(idx)
            self._normalize_page_visibility(idx)
        self._play_sfx('open')
        self.update_focus()

    def update_focus(self):
        self.top_tabs.set_current(self.tab_idx)
        tab_name = self.tabs[self.tab_idx]
        page = self._current_page()
        self.desc.setText(self.page_specs.get(tab_name, {}).get('hint', f'{tab_name}: use arrows and Enter'))

        if self.focus_area == 'left':
            if page.left_tiles:
                self.focus_idx = max(0, min(self.focus_idx, len(page.left_tiles) - 1))
            else:
                self.focus_area = 'center'
                self.focus_idx = 0
        elif self.focus_area == 'right':
            if page.right_tiles:
                self.focus_idx = max(0, min(self.focus_idx, len(page.right_tiles) - 1))
            else:
                self.focus_area = 'center'
                self.focus_idx = 0
        else:
            self.focus_idx = 0

        for i, t in enumerate(page.left_tiles):
            t.set_selected(self.focus_area == 'left' and self.focus_idx == i)
        for i, t in enumerate(page.right_tiles):
            t.set_selected(self.focus_area == 'right' and self.focus_idx == i)
        page.hero.set_selected(self.focus_area == 'center')

        cur = (self.tab_idx, self.focus_area, self.focus_idx)
        if self._last_focus_state is None:
            self._last_focus_state = cur
        elif cur != self._last_focus_state:
            self._play_sfx('hover')
            self._last_focus_state = cur

    def _on_tab_changed(self, idx):
        self._switch_tab(idx, animate=True, keep_tabs_focus=True)

    def _open_current_tab_menu(self):
        name = self.tabs[self.tab_idx]
        options = self.tab_actions.get(name, [])
        if not options:
            self._msg(name, 'No actions configured.')
            return
        self._menu(name, options)

    def _save_recent(self, action):
        try:
            arr = json.loads(RECENT_FILE.read_text()) if RECENT_FILE.exists() else []
            arr = [x for x in arr if x != action]
            arr.insert(0, action)
            RECENT_FILE.write_text(json.dumps(arr[:20], indent=2))
        except Exception:
            pass

    def _play_sfx(self, name):
        if name == 'hover':
            now = time.monotonic()
            if (now - self._last_hover_at) < 0.08:
                return
            self._last_hover_at = now
        candidates = []
        base = self.sfx.get(name)
        if base:
            candidates.append(base)
        candidates.extend(self.sfx_aliases.get(name, []))
        snd = pick_existing_sound(candidates)
        if snd is None:
            return
        play_media(snd, video=False, blocking=False)

    def _run(self, cmd, args=None):
        self._play_sfx('open')
        try:
            QtCore.QProcess.startDetached(cmd, args or [])
        except Exception:
            pass

    def _run_terminal(self, shell_cmd):
        self._play_sfx('open')
        hold = shell_cmd + '; echo; read -r -p "Press Enter to close..." _'
        if shutil.which('x-terminal-emulator'):
            QtCore.QProcess.startDetached('x-terminal-emulator', ['-e', '/bin/bash', '-lc', hold])
            return
        if shutil.which('gnome-terminal'):
            QtCore.QProcess.startDetached('gnome-terminal', ['--', '/bin/bash', '-lc', hold])
            return
        if shutil.which('konsole'):
            QtCore.QProcess.startDetached('konsole', ['-e', '/bin/bash', '-lc', hold])
            return
        if shutil.which('xterm'):
            QtCore.QProcess.startDetached('xterm', ['-e', '/bin/bash', '-lc', hold])
            return
        QtCore.QProcess.startDetached('/bin/bash', ['-lc', shell_cmd])

    def _open_url(self, url):
        if QtWebEngineWidgets is not None:
            try:
                w = WebKioskWindow(url, self)
                self._web_windows.append(w)
                w.showFullScreen()
                self._play_sfx('open')
                return
            except Exception:
                pass
        kiosk = XUI_HOME / 'bin' / 'xui_browser.sh'
        if kiosk.exists():
            self._run('/bin/sh', ['-c', f'"{kiosk}" --kiosk "{url}"'])
            return
        if shutil.which('xdg-open'):
            self._run('/bin/sh', ['-c', f'xdg-open "{url}"'])
            return
        self._msg('Browser', f'No browser launcher available.\n{url}')

    def _open_social_chat(self):
        self._play_sfx('open')
        d = SocialOverlay(self)
        d.exec_()
        self._play_sfx('close')

    def _platform_specs(self):
        xui_bin = XUI_HOME / 'bin'
        return {
            'steam': {
                'label': 'Steam',
                'launch': xui_bin / 'xui_steam.sh',
                'install': xui_bin / 'xui_install_steam.sh',
            },
            'retroarch': {
                'label': 'RetroArch',
                'launch': xui_bin / 'xui_retroarch.sh',
                'install': xui_bin / 'xui_install_retroarch.sh',
            },
            'lutris': {
                'label': 'Lutris',
                'launch': xui_bin / 'xui_lutris.sh',
                'install': xui_bin / 'xui_install_lutris.sh',
            },
            'heroic': {
                'label': 'Heroic',
                'launch': xui_bin / 'xui_heroic.sh',
                'install': xui_bin / 'xui_install_heroic.sh',
            },
        }

    def _platform_available(self, launch_script):
        if not Path(launch_script).exists():
            return False
        rc = subprocess.call(
            ['/bin/sh', '-c', f'"{launch_script}" --check'],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return rc == 0

    def _launch_platform(self, key):
        specs = self._platform_specs()
        spec = specs.get(str(key).lower())
        if not spec:
            self._msg('Platform', f'Unknown platform: {key}')
            return
        label = spec['label']
        launch_script = spec['launch']
        install_script = spec['install']
        if self._platform_available(launch_script):
            self._run('/bin/sh', ['-c', f'"{launch_script}"'])
            return
        ask = self._ask_yes_no(
            label,
            f'{label} is not installed yet.\n\nDo you want to run installer now?'
        )
        if ask:
            if Path(install_script).exists():
                self._run_terminal(f'"{install_script}"')
            else:
                self._msg(label, f'Installer not found: {install_script}')

    def _install_platform(self, key):
        specs = self._platform_specs()
        spec = specs.get(str(key).lower())
        if not spec:
            self._msg('Platform', f'Unknown platform: {key}')
            return
        install_script = spec['install']
        if Path(install_script).exists():
            self._run_terminal(f'"{install_script}"')
        else:
            self._msg(spec['label'], f'Installer not found: {install_script}')

    def _show_platform_status(self):
        status_script = XUI_HOME / 'bin' / 'xui_platform_status.sh'
        if status_script.exists():
            out = subprocess.getoutput(f'/bin/sh -c "{status_script}"')
            self._msg('Games Platforms', out or 'No platform status data.')
            return
        compat = XUI_HOME / 'bin' / 'xui_compat_status.sh'
        out = subprocess.getoutput(f'/bin/sh -c "{compat}"') if compat.exists() else ''
        self._msg('Games Platforms', out or 'No status script available.')

    def _msg(self, title, text):
        self._play_sfx('open')
        self._popup_message(title, text, QtWidgets.QMessageBox.Information, QtWidgets.QMessageBox.Ok)
        self._play_sfx('close')

    def _popup_message(self, title, text, icon, buttons, default_button=None):
        box = QtWidgets.QMessageBox(self)
        box.setWindowTitle(title)
        box.setText(str(text))
        box.setIcon(icon)
        box.setStandardButtons(buttons)
        if default_button is not None:
            box.setDefaultButton(default_button)
        esc_btn = (
            box.button(QtWidgets.QMessageBox.Cancel)
            or box.button(QtWidgets.QMessageBox.No)
            or box.button(QtWidgets.QMessageBox.Ok)
        )
        if esc_btn is not None:
            box.setEscapeButton(esc_btn)
        return box.exec_()

    def _ask_yes_no(self, title, text):
        self._play_sfx('open')
        ans = self._popup_message(
            title,
            text,
            QtWidgets.QMessageBox.Question,
            QtWidgets.QMessageBox.Yes | QtWidgets.QMessageBox.No,
            QtWidgets.QMessageBox.No,
        )
        self._play_sfx('close')
        return ans == QtWidgets.QMessageBox.Yes

    def _input_int(self, title, label, value, minv, maxv, step=1):
        d = EscInputDialog(self)
        d.setWindowTitle(title)
        d.setLabelText(label)
        d.setInputMode(QtWidgets.QInputDialog.IntInput)
        d.setIntRange(minv, maxv)
        d.setIntStep(step)
        d.setIntValue(value)
        ok = d.exec_() == QtWidgets.QDialog.Accepted
        return d.intValue(), ok

    def _input_text(self, title, label, text=''):
        d = EscInputDialog(self)
        d.setWindowTitle(title)
        d.setLabelText(label)
        d.setInputMode(QtWidgets.QInputDialog.TextInput)
        d.setTextValue(text)
        ok = d.exec_() == QtWidgets.QDialog.Accepted
        return d.textValue(), ok

    def _input_item(self, title, label, items, current=0):
        d = EscInputDialog(self)
        d.setWindowTitle(title)
        d.setLabelText(label)
        d.setInputMode(QtWidgets.QInputDialog.TextInput)
        d.setComboBoxItems(list(items))
        d.setComboBoxEditable(False)
        if items:
            idx = max(0, min(current, len(items) - 1))
            d.setTextValue(items[idx])
        ok = d.exec_() == QtWidgets.QDialog.Accepted
        return d.textValue(), ok

    def _menu(self, title, options):
        self._play_sfx('open')
        descriptions = self._menu_descriptions(title, options)
        d = QuickMenu(title, options, descriptions, self)
        if d.exec_() == QtWidgets.QDialog.Accepted:
            s = d.selected()
            if s:
                self.handle_action(s)
        else:
            self._play_sfx('back')

    def _choose_from_menu(self, title, options, descriptions=None):
        d = QuickMenu(title, options, descriptions or {}, self)
        if d.exec_() == QtWidgets.QDialog.Accepted:
            return d.selected()
        return None

    def _scan_media_candidates(self, tray_action='scan'):
        if tray_action in ('toggle', 'open', 'close') and shutil.which('eject'):
            if tray_action == 'toggle':
                subprocess.getoutput('/bin/sh -c "eject -T >/dev/null 2>&1 || true"')
            elif tray_action == 'open':
                subprocess.getoutput('/bin/sh -c "eject >/dev/null 2>&1 || true"')
            elif tray_action == 'close':
                subprocess.getoutput('/bin/sh -c "eject -t >/dev/null 2>&1 || true"')
            time.sleep(1.2)

        scan_script = XUI_HOME / 'bin' / 'xui_scan_media_games.sh'
        out = ''
        if scan_script.exists():
            out = subprocess.getoutput(f'/bin/sh -c {shlex.quote(str(scan_script))}')
        else:
            out = 'Scan script not found.'

        list_file = XUI_HOME / 'data' / 'media_games.txt'
        files = []
        try:
            if list_file.exists():
                for line in list_file.read_text(encoding='utf-8', errors='ignore').splitlines():
                    s = line.strip()
                    if s.startswith('/'):
                        files.append(s)
        except Exception:
            files = []
        return files, out

    def _launch_media_candidate(self, target):
        xui = str(XUI_HOME)
        q_target = shlex.quote(str(target))
        ext = Path(target).suffix.lower().lstrip('.')
        if ext in ('exe', 'msi', 'bat'):
            self._run('/bin/sh', ['-c', f'"{xui}/bin/xui_wine_run.sh" {q_target}'])
            return
        if ext == 'appimage':
            self._run('/bin/sh', ['-c', f'chmod +x {q_target} >/dev/null 2>&1 || true; {q_target}'])
            return
        if ext == 'sh':
            self._run('/bin/sh', ['-c', f'bash {q_target}'])
            return
        if ext == 'desktop':
            if shutil.which('gtk-launch'):
                app_id = shlex.quote(Path(target).stem)
                self._run('/bin/sh', ['-c', f'gtk-launch {app_id} || xdg-open {q_target}'])
            else:
                self._run('/bin/sh', ['-c', f'xdg-open {q_target}'])
            return
        if ext in ('iso', 'chd', 'cue'):
            retro = XUI_HOME / 'bin' / 'xui_retroarch.sh'
            if retro.exists():
                self._run('/bin/sh', ['-c', f'"{retro}" {q_target}'])
            else:
                self._run('/bin/sh', ['-c', f'xdg-open {q_target}'])
            return
        self._run('/bin/sh', ['-c', f'xdg-open {q_target}'])

    def _open_tray_dashboard_menu(self):
        tray_action = 'toggle'
        last_scan = ''
        while True:
            files, last_scan = self._scan_media_candidates(tray_action)
            tray_action = 'scan'

            options = ['Rescan Media']
            if shutil.which('eject'):
                options += ['Toggle Tray', 'Open Tray', 'Close Tray']

            label_to_target = {}
            seen = {}
            for f in files[:40]:
                name = Path(f).name or f
                base = f'Launch: {name}'
                n = seen.get(base, 0) + 1
                seen[base] = n
                label = base if n == 1 else f'{base} [{n}]'
                options.append(label)
                label_to_target[label] = f

            if not label_to_target:
                options.append('(No media candidates)')
            options += ['Show Scan Log', 'Back']

            descriptions = {
                'Rescan Media': 'Refresh mounted media list and scan for launchable files.',
                'Toggle Tray': 'Toggle DVD tray open/close and rescan.',
                'Open Tray': 'Open optical tray and rescan.',
                'Close Tray': 'Close optical tray and rescan.',
                '(No media candidates)': 'No executable/game file found in mounted media.',
                'Show Scan Log': 'View raw scanner output from the last scan.',
                'Back': 'Return to dashboard.',
            }
            for label, target in label_to_target.items():
                descriptions[label] = target

            pick = self._choose_from_menu('Open Tray', options, descriptions)
            if not pick or pick == 'Back':
                return
            if pick == 'Rescan Media':
                tray_action = 'scan'
                continue
            if pick == 'Toggle Tray':
                tray_action = 'toggle'
                continue
            if pick == 'Open Tray':
                tray_action = 'open'
                continue
            if pick == 'Close Tray':
                tray_action = 'close'
                continue
            if pick == 'Show Scan Log':
                self._msg('Open Tray Scan', last_scan or 'No scan output.')
                tray_action = 'scan'
                continue
            if pick == '(No media candidates)':
                self._msg('Open Tray', 'No executable/game candidate found.')
                tray_action = 'scan'
                continue
            target = label_to_target.get(pick)
            if target:
                self._launch_media_candidate(target)
                return

    def _menu_descriptions(self, title, options):
        generic = {
            'Open Tray': 'Open tray control menu inside dashboard (no external terminal).',
            'System Info': 'Shows OS, memory, storage and runtime info.',
            'Power Profile': 'Choose eco, balanced or performance power mode.',
            'Battery Saver': 'Toggles battery saver mode instantly.',
            'Family': 'Manage family and local user profile settings.',
            'Theme Toggle': 'Switches dashboard theme quickly.',
            'Setup Wizard': 'Run Xbox style first setup to configure gamertag and profile.',
            'Battery Info': 'Displays battery status and health values.',
            'Turn Off': 'Closes dashboard and returns to desktop.',
            'Friends': 'View friend list and online status.',
            'Messages': 'Open in-dashboard social messaging overlay.',
            'LAN Chat': 'Chat with peers in LAN/P2P without leaving dashboard.',
            'LAN Status': 'Shows local network and LAN adapter status.',
            'P2P Internet Help': 'Guide for Internet peer connection (IP:port / VPN).',
            'Party': 'Shows active local session users.',
            'Gamer Card': 'Shows gamertag and sign-in state.',
            'Social Apps': 'Opens social related tools and options.',
            'Sign In': 'Toggle local sign-in state for gamer profile.',
            'Steam': 'Launch Steam/compat launcher.',
            'RetroArch': 'Launch RetroArch frontend.',
            'Lutris': 'Launch Lutris game platform.',
            'Heroic': 'Launch Heroic Games Launcher.',
            'Games Integrations': 'Manage Steam/RetroArch/Lutris/Heroic from one place.',
            'Platforms Status': 'Show installation/status of integrated game platforms.',
            'Install RetroArch': 'Install RetroArch from package manager or Flatpak.',
            'Install Lutris': 'Install Lutris from package manager or Flatpak.',
            'Install Heroic': 'Install Heroic Games Launcher.',
            'Store': 'Open XUI store and inventory.',
            'Casino': 'Launch casino minigame.',
            'Runner': 'Launch runner minigame.',
            'Missions': 'Open missions and rewards.',
            'Misiones': 'Open missions and rewards.',
            'Web Control': 'Control local web API service.',
            'Web Start': 'Start web control API service.',
            'Web Status': 'Check web control service status.',
            'Web Stop': 'Stop web control API service.',
            'App Launcher': 'Quick launch applications from system.',
            'Service Manager': 'Manage XUI user services.',
            'Developer Tools': 'Open diagnostics and advanced tools.',
            'Compatibility Status': 'Show x86/Steam compatibility status.',
            'Install Box64': 'Install Box64 runtime for ARM compatibility.',
            'Install Steam': 'Install Steam and dependencies.',
            'Playlist': 'Play local playlist/music tools.',
            'Visualizer': 'Open visualizer/music playback mode.',
            'System Music': 'Open system music controls.',
            'Media Player': 'Play startup/media video content.',
            'Boot Video': 'Replay startup boot video.',
            'Utilities': 'Open utility menu with system tools.',
            'Network Info': 'Displays network interfaces and routes.',
            'Disk Usage': 'Shows storage usage summary.',
            'Diagnostics': 'Run diagnostics helper.',
            'Update Check': 'Checks if updates are available.',
            'System Update': 'Runs distro package update flow.',
        }
        out = {}
        prefix = (title or 'menu').strip()
        for opt in options or []:
            if opt in generic:
                out[opt] = generic[opt]
            else:
                out[opt] = f'{prefix}: {opt}'
        return out

    def handle_action(self, action):
        self._save_recent(action)
        self._play_sfx('select')
        xui = str(XUI_HOME)
        if action in ('Hub', 'Social Hub', 'Games Hub', 'Media Hub', 'Music Hub', 'Apps Hub', 'Settings Hub'):
            self._open_current_tab_menu()
        elif action == 'Open Tray':
            self._open_tray_dashboard_menu()
        elif action == 'My Pins':
            self._menu('My Pins', ['Casino', 'Runner', 'Store', 'System Info', 'Web Control'])
        elif action == 'Recent':
            try:
                arr = json.loads(RECENT_FILE.read_text()) if RECENT_FILE.exists() else []
            except Exception:
                arr = []
            self._menu('Recent', arr or ['No recent actions'])
        elif action == 'Casino':
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_python.sh {xui}/casino/casino.py'])
        elif action == 'Runner':
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_python.sh {xui}/games/runner.py'])
        elif action == 'Steam':
            self._launch_platform('steam')
        elif action in ('Store', 'Avatar Store'):
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_store.sh'])
        elif action in ('Missions', 'Misiones'):
            self._play_sfx('achievement')
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_missions.sh'])
        elif action == 'LAN':
            self._menu('LAN', ['LAN Chat', 'LAN Status', 'P2P Internet Help'])
        elif action in ('Messages', 'LAN Chat'):
            self._open_social_chat()
        elif action == 'LAN Status':
            out = subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_lan_status.sh"')
            self._msg('LAN Status', out or 'No network data.')
        elif action == 'P2P Internet Help':
            out = subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_lan_status.sh"')
            self._msg('P2P Internet',
                      'Modo recomendado: usa Tailscale/ZeroTier para enlazar dos redes como si fueran LAN.\n'
                      'Alternativa directa: conecta por IP:PUERTO (reenvia puerto TCP 38600 en el router).\n\n'
                      f'{out}')
        elif action == 'Party':
            out = subprocess.getoutput("who | awk '{print $1}' | sort -u")
            self._msg('Party', out or 'No active users detected.')
        elif action == 'Gamer Card':
            try:
                p = json.loads(PROFILE_FILE.read_text()) if PROFILE_FILE.exists() else {}
            except Exception:
                p = {}
            signed = 'Yes' if p.get('signed_in') else 'No'
            self._msg('Gamer Card', f"Gamertag: {p.get('gamertag','Player1')}\nSigned In: {signed}")
        elif action == 'Social Apps':
            self._menu('Social Apps', ['Friends', 'Messages', 'LAN Chat', 'LAN Status', 'P2P Internet Help', 'Party', 'Avatar Store'])
        elif action == 'Friends':
            try:
                friends = json.loads(FRIENDS_FILE.read_text()) if FRIENDS_FILE.exists() else []
                txt = '\n'.join([f"{f.get('name','Friend')} - {'Online' if f.get('online') else 'Offline'}" for f in friends])
            except Exception:
                txt = ''
            self._msg('Friends', txt or 'No friends found.')
        elif action == 'Sign In':
            try:
                p = json.loads(PROFILE_FILE.read_text()) if PROFILE_FILE.exists() else {}
            except Exception:
                p = {}
            p['signed_in'] = not bool(p.get('signed_in', False))
            p['gamertag'] = p.get('gamertag', 'Player1')
            PROFILE_FILE.write_text(json.dumps(p, indent=2))
            self._msg('Profile', 'Signed in.' if p['signed_in'] else 'Signed out.')
        elif action == 'Utilities':
            self._menu('Utilities', [
                'System Info', 'Web Control', 'Theme Toggle', 'Power Profile', 'Battery Saver',
                'Update Check', 'System Update', 'Steam', 'Compat X86', 'File Manager',
                'Gallery', 'Screenshot', 'Calculator', 'Gamepad Test', 'WiFi Toggle', 'Bluetooth Toggle',
                'Terminal', 'Process Monitor', 'Network Info', 'Disk Usage', 'Battery Info', 'Diagnostics',
                'HTTP Server', 'RetroArch', 'Torrent', 'Kodi', 'Screen Recorder', 'Clipboard Tool',
                'Emoji Picker', 'Cron Manager', 'Backup Data', 'Restore Last Backup', 'Plugin Manager',
                'Logs Viewer', 'JSON Browser', 'Archive Manager', 'Hash Tool', 'Ping Test',
                'Docker Status', 'VM Status', 'Open Notes', 'App Launcher', 'Service Manager',
                'Developer Tools', 'Scan Media Games', 'Install Wine Runtime', 'Games Integrations'
            ])
        elif action == 'Games Integrations':
            self._menu('Games Integrations', [
                'Platforms Status',
                'Steam', 'Install Steam',
                'RetroArch', 'Install RetroArch',
                'Lutris', 'Install Lutris',
                'Heroic', 'Install Heroic',
                'Compat X86'
            ])
        elif action == 'Developer Tools':
            self._menu('Developer Tools', [
                'Terminal', 'Process Monitor', 'Logs Viewer', 'JSON Browser', 'Hash Tool',
                'Docker Status', 'VM Status', 'Network Info', 'Disk Usage', 'Diagnostics'
            ])
        elif action == 'Service Manager':
            self._menu('Service Manager', [
                'Service Status', 'Web Start', 'Web Stop', 'Web Status', 'Restart Dashboard Service'
            ])
        elif action == 'Service Status':
            self._run_terminal(f'"{xui}/bin/xui_service_status.sh"')
        elif action == 'Compat X86':
            self._menu('Compat X86', [
                'Platforms Status',
                'Compatibility Status',
                'Install Box64',
                'Install Steam', 'Install RetroArch', 'Install Lutris', 'Install Heroic',
                'Steam', 'RetroArch', 'Lutris', 'Heroic'
            ])
        elif action == 'Compatibility Status':
            subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_mission_mark.sh m4"')
            out = subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_compat_status.sh"')
            self._msg('Compat X86', out or 'No compatibility data.')
        elif action == 'Install Box64':
            self._run_terminal(f'"{xui}/bin/xui_install_box64.sh"')
        elif action == 'Install Steam':
            self._install_platform('steam')
        elif action == 'Install RetroArch':
            self._install_platform('retroarch')
        elif action == 'Install Lutris':
            self._install_platform('lutris')
        elif action == 'Install Heroic':
            self._install_platform('heroic')
        elif action == 'Platforms Status':
            self._show_platform_status()
        elif action == 'Game Details':
            self._msg('Games', 'Use Casino, Runner, Missions o Steam para jugar.')
        elif action in ('Media Player', 'Boot Video'):
            p = ASSETS / 'startup.mp4'
            if p.exists():
                self._run('/bin/sh', ['-c', f'mpv --really-quiet --fullscreen "{p}"'])
            else:
                self._msg('Media', 'No startup.mp4 found.')
        elif action == 'Netflix':
            self._open_url('https://www.netflix.com')
        elif action == 'YouTube':
            self._open_url('https://www.youtube.com')
        elif action == 'ESPN':
            self._open_url('https://www.espn.com')
        elif action == 'Startup Sound':
            p = ASSETS / 'startup.mp3'
            if p.exists():
                self._run('/bin/sh', ['-c', f'mpv --no-video --really-quiet "{p}"'])
            else:
                self._msg('Music', 'No startup.mp3 found.')
        elif action == 'All Audio Files':
            files = sorted([f.name for f in ASSETS.glob('*.mp3')])
            self._msg('Audio', '\n'.join(files) if files else 'No mp3 files found.')
        elif action in ('Playlist', 'Visualizer', 'System Music'):
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_music.sh'])
        elif action == 'Mute / Unmute':
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_volume.sh mute'])
        elif action == 'System Info':
            out = subprocess.getoutput("uname -srmo; free -h | sed -n '1,3p'; df -h / | sed -n '1,2p'")
            self._msg('System Info', out or 'No data.')
        elif action == 'Web Control':
            self._menu('Web Control', ['Web Start', 'Web Status', 'Web Stop'])
        elif action == 'Web Start':
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_web_control.sh start'])
        elif action == 'Web Status':
            out = subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_web_control.sh status"')
            self._msg('Web Control', out or 'No status')
        elif action == 'Web Stop':
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_web_control.sh stop'])
        elif action == 'Theme Toggle':
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_theme.sh toggle'])
        elif action == 'Setup Wizard':
            setup = XUI_HOME / 'bin' / 'xui_first_setup.py'
            runner = XUI_HOME / 'bin' / 'xui_python.sh'
            if setup.exists():
                if runner.exists():
                    self._run('/bin/sh', ['-c', f'"{runner}" "{setup}"'])
                else:
                    self._run('/bin/sh', ['-c', f'python3 "{setup}"'])
            else:
                self._msg('Setup Wizard', 'Setup wizard not found.')
        elif action == 'File Manager':
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_filemgr.sh "$HOME"'])
        elif action == 'Gallery':
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_gallery.sh "$HOME/Pictures"'])
        elif action == 'Screenshot':
            out = subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_screenshot.sh"')
            self._msg('Screenshot', out or 'Capture finished.')
        elif action == 'Calculator':
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_calc.sh'])
        elif action == 'App Launcher':
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_app_launcher.sh'])
        elif action == 'Scan Media Games':
            self._run_terminal(f'"{xui}/bin/xui_scan_media_games.sh"')
        elif action == 'Install Wine Runtime':
            self._run_terminal(f'"{xui}/bin/xui_install_wine.sh"')
        elif action == 'Open Notes':
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_note.sh'])
        elif action == 'Terminal':
            self._run_terminal('/bin/bash')
        elif action == 'Process Monitor':
            self._run_terminal(f'"{xui}/bin/xui_process_monitor.sh"')
        elif action == 'Network Info':
            self._msg('Network Info', subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_netinfo.sh"') or 'No network data.')
        elif action == 'Disk Usage':
            self._msg('Disk Usage', subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_disk_usage.sh"') or 'No disk data.')
        elif action == 'Battery Info':
            out = subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_battery_info.sh"')
            self._msg('Battery Info', out or 'No battery data.')
        elif action == 'Diagnostics':
            self._run_terminal(f'"{xui}/bin/xui_diag.sh"')
        elif action == 'HTTP Server':
            p, ok = self._input_int('HTTP Server', 'Port:', 8000, 1, 65535, 1)
            if ok:
                self._run_terminal(f'"{xui}/bin/xui_http_server.sh" {p} "$HOME"')
        elif action == 'RetroArch':
            self._launch_platform('retroarch')
        elif action == 'Lutris':
            self._launch_platform('lutris')
        elif action == 'Heroic':
            self._launch_platform('heroic')
        elif action == 'Torrent':
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_torrent.sh'])
        elif action == 'Kodi':
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_kodi.sh'])
        elif action == 'Screen Recorder':
            self._run_terminal(f'"{xui}/bin/xui_screenrec.sh"')
        elif action == 'Clipboard Tool':
            txt = subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_clip.sh get"')
            self._msg('Clipboard', txt if txt else 'Clipboard is empty.')
        elif action == 'Logs Viewer':
            self._run_terminal(f'"{xui}/bin/xui_logs_view.sh"')
        elif action == 'JSON Browser':
            self._run_terminal(f'"{xui}/bin/xui_json_browser.sh"')
        elif action == 'Archive Manager':
            self._run_terminal(f'"{xui}/bin/xui_archive_tool.sh"')
        elif action == 'Hash Tool':
            self._run_terminal(f'"{xui}/bin/xui_hash_tool.sh"')
        elif action == 'Ping Test':
            host, ok = self._input_text('Ping Test', 'Host/IP:', '8.8.8.8')
            if ok and host:
                out = subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_ping_test.sh {host}"')
                self._msg('Ping Test', out or 'No output')
        elif action == 'Docker Status':
            self._msg('Docker Status', subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_docker_status.sh"') or 'No data.')
        elif action == 'VM Status':
            self._msg('VM Status', subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_vm_status.sh"') or 'No data.')
        elif action == 'Emoji Picker':
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_emoji.sh'])
        elif action == 'Cron Manager':
            self._run_terminal(f'"{xui}/bin/xui_cron.sh" edit')
        elif action == 'Backup Data':
            out = subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_backup.sh"')
            self._msg('Backup', out or 'Backup finished.')
        elif action == 'Restore Last Backup':
            self._run_terminal(f'"{xui}/bin/xui_restore_last_backup.sh"')
        elif action == 'Plugin Manager':
            self._run_terminal(f'"{xui}/bin/xui_plugin_mgr.sh" list')
        elif action == 'Restart Dashboard Service':
            out = subprocess.getoutput('/bin/sh -c "systemctl --user restart xui-dashboard.service 2>&1 || true"')
            self._msg('Dashboard Service', out or 'Restart requested.')
        elif action == 'Gamepad Test':
            self._run_terminal(f'"{xui}/bin/xui_gamepad_test.sh"')
        elif action == 'WiFi Toggle':
            out = subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_wifi_toggle.sh"')
            self._msg('WiFi', out or 'No output')
        elif action == 'Bluetooth Toggle':
            out = subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_bluetooth_toggle.sh"')
            self._msg('Bluetooth', out or 'No output')
        elif action == 'Power Profile':
            prof, ok = self._input_item('Power Profile', 'Choose profile:', ['eco', 'balanced', 'performance'], 1)
            if ok and prof:
                self._run('/bin/sh', ['-c', f'{xui}/bin/xui_battery_profile.sh {prof}'])
        elif action == 'Battery Saver':
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_battery_saver.sh toggle'])
        elif action == 'Update Check':
            self._msg('Update', subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_update_check.sh status"'))
        elif action == 'System Update':
            self._run_terminal(f'"{xui}/bin/xui_update_system.sh"')
        elif action == 'Family':
            out = subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_profile.sh list"')
            self._msg('Family', out or 'No profiles found.')
        elif action == 'Turn Off':
            if self._ask_yes_no('Turn Off', 'Apagar dashboard y salir?'):
                QtWidgets.QApplication.quit()
        elif action == 'Exit':
            if self._ask_yes_no('Exit', 'Salir al escritorio?'):
                QtWidgets.QApplication.quit()
        else:
            self._msg('Action', f'{action} launched.')

    def keyPressEvent(self, e):
        k = e.key()
        if k in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self._play_sfx('back')
            if self.focus_area in ('left', 'right'):
                self.focus_area = 'center'
                self.focus_idx = 0
                self.update_focus()
                return
            if self.focus_area == 'center':
                self.focus_area = 'tabs'
                self.focus_idx = 0
                self.update_focus()
                return
            if self._ask_yes_no('Exit', 'Salir al escritorio?'):
                QtWidgets.QApplication.quit()
            return
        if self._tab_animating:
            return
        page = self._current_page()
        if k == QtCore.Qt.Key_Left:
            if self.focus_area == 'tabs':
                self._switch_tab(self.tab_idx - 1, animate=True, keep_tabs_focus=True)
                return
            elif self.focus_area == 'center':
                if page.left_tiles:
                    self.focus_area = 'left'
                    self.focus_idx = min(self.focus_idx, len(page.left_tiles) - 1)
            elif self.focus_area == 'right':
                self.focus_area = 'center'
            self.update_focus(); return
        if k == QtCore.Qt.Key_Right:
            if self.focus_area == 'tabs':
                self._switch_tab(self.tab_idx + 1, animate=True, keep_tabs_focus=True)
                return
            elif self.focus_area == 'left':
                self.focus_area = 'center'
            elif self.focus_area == 'center':
                if page.right_tiles:
                    self.focus_area = 'right'
                    self.focus_idx = min(self.focus_idx, len(page.right_tiles) - 1)
            self.update_focus(); return
        if k == QtCore.Qt.Key_Up:
            if self.focus_area in ('left', 'right'):
                self.focus_idx = max(0, self.focus_idx - 1)
            elif self.focus_area == 'center':
                self.focus_area = 'tabs'
            self.update_focus(); return
        if k == QtCore.Qt.Key_Down:
            if self.focus_area == 'tabs':
                self.focus_area = 'center'
            elif self.focus_area == 'left':
                self.focus_idx = min(len(page.left_tiles)-1, self.focus_idx + 1) if page.left_tiles else 0
            elif self.focus_area == 'right':
                self.focus_idx = min(len(page.right_tiles)-1, self.focus_idx + 1) if page.right_tiles else 0
            self.update_focus(); return
        if k == QtCore.Qt.Key_Tab:
            order = ['tabs']
            if page.left_tiles:
                order.append('left')
            order.append('center')
            if page.right_tiles:
                order.append('right')
            idx = order.index(self.focus_area) if self.focus_area in order else 0
            self.focus_area = order[(idx + 1) % len(order)]
            self.focus_idx = 0
            self.update_focus(); return
        if k in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter, QtCore.Qt.Key_Space):
            if self.focus_area == 'tabs':
                self.focus_area = 'center'
                self.focus_idx = 0
                self._play_sfx('select')
                self.update_focus()
            elif self.focus_area == 'center':
                self.handle_action(page.hero.action)
            elif self.focus_area == 'left':
                if page.left_tiles:
                    self.handle_action(page.left_tiles[self.focus_idx].action)
            else:
                if page.right_tiles:
                    self.handle_action(page.right_tiles[self.focus_idx].action)
            return
        if k == QtCore.Qt.Key_F1:
            self._menu('Guide', ['home', 'social', 'games', 'tv & movies', 'music', 'apps', 'settings', 'Exit'])
            return
        super().keyPressEvent(e)


def main():
    app = QtWidgets.QApplication(sys.argv)
    app.setApplicationName('XUI Xbox Style')
    f = app.font()
    f.setPointSize(12)
    app.setFont(f)
    play_startup_video()
    w = Dashboard()
    try:
        w.showFullScreen()
    except Exception:
        w.show()
    sys.exit(app.exec_())


if __name__ == '__main__':
    main()
PY
  chmod a+x "$DASH_DIR/pyqt_dashboard_improved.py" || true
  info "Wrote dashboard to $DASH_DIR/pyqt_dashboard_improved.py"
}

# If an enhanced dashboard file exists next to this installer (pyqt_dashboard_improved_fixed.py),
# offer to deploy it non-destructively: backup existing dashboard and copy the enhanced one.
deploy_custom_dashboard(){
    local script_dir src dst bak
    if [ "${XUI_USE_EXTERNAL_DASHBOARD:-0}" != "1" ]; then
        info "Skipping external dashboard override (use --use-external-dashboard to enable)"
        return 0
    fi
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    src="$script_dir/pyqt_dashboard_improved_fixed.py"
    dst="$DASH_DIR/pyqt_dashboard_improved.py"
    if [ ! -f "$src" ]; then
        # nothing to do
        return 0
    fi
    info "Found enhanced dashboard at $src"
    mkdir -p "$DASH_DIR" "$BACKUP_DIR"
    if [ -f "$dst" ]; then
        if cmp -s "$src" "$dst"; then
            info "Installed dashboard already up-to-date; skipping"
            return 0
        fi
        if confirm "Replace existing dashboard with enhanced version from installer?"; then
            bak="$BACKUP_DIR/pyqt_dashboard_improved.$(date +%Y%m%d%H%M%S).bak"
            if cp -f "$dst" "$bak" 2>/dev/null; then
                info "Backed up existing dashboard to $bak"
            else
                warn "Failed to create backup of existing dashboard; aborting"
                return 1
            fi
            if cp -f "$src" "$dst"; then
                chmod a+x "$dst" || true
                info "Replaced installed dashboard with enhanced version"
            else
                warn "Failed to copy enhanced dashboard to $dst"
                return 1
            fi
        else
            info "User declined to replace existing dashboard"
        fi
    else
        if confirm "Install enhanced dashboard from installer to $dst?"; then
            mkdir -p "$(dirname "$dst")"
            if cp -f "$src" "$dst"; then
                chmod a+x "$dst" || true
                info "Installed enhanced dashboard to $dst"
            else
                warn "Failed to copy enhanced dashboard to $dst"
            fi
        fi
    fi
}

write_startup_wrapper(){
  cat > "$BIN_DIR/xui_startup_and_dashboard.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
ASSETS_DIR="$HOME/.xui/assets"
DASH_SCRIPT="$HOME/.xui/dashboard/pyqt_dashboard_improved.py"
PY_RUNNER="$HOME/.xui/bin/xui_python.sh"
info(){ echo "[INFO] $*"; }
if [ -f "$DASH_SCRIPT" ]; then
  if [ -x "$PY_RUNNER" ]; then
    exec "$PY_RUNNER" "$DASH_SCRIPT"
  fi
  exec python3 "$DASH_SCRIPT"
else
  echo "Dashboard script not found: $DASH_SCRIPT" >&2
  exit 1
fi
SH
  chmod a+x "$BIN_DIR/xui_startup_and_dashboard.sh" || true
  info "Wrote startup wrapper to $BIN_DIR/xui_startup_and_dashboard.sh"
}

write_autostart(){
  cat > "$AUTOSTART_DIR/xui-dashboard.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=XUI Dashboard
Exec=$BIN_DIR/xui_startup_and_dashboard.sh
Terminal=false
StartupNotify=false
X-GNOME-Autostart-enabled=true
Hidden=false
DESK
  info "Wrote autostart desktop to $AUTOSTART_DIR/xui-dashboard.desktop"
}

install_media_tools_if_requested(){
    # Optionally install common media tools (mpv, ffmpeg, cwebp) if user allows.
    # Set AUTO_INSTALL_TOOLS=1 to attempt automatic installation (uses sudo when necessary).
    pkgs=(mpv ffmpeg cwebp)
    # map to distro packages when possible
    if command -v apt >/dev/null 2>&1; then
        instal_cmd="sudo apt update && sudo apt install -y"
    elif command -v dnf >/dev/null 2>&1; then
        instal_cmd="sudo dnf install -y"
    elif command -v pacman >/dev/null 2>&1; then
        instal_cmd="sudo pacman -S --noconfirm"
    else
        instal_cmd=""
    fi

    missing=()
    for p in "${pkgs[@]}"; do
        if ! command -v "$p" >/dev/null 2>&1; then
            missing+=($p)
        fi
    done

    if [ ${#missing[@]} -eq 0 ]; then
        info "All media tools present: ${pkgs[*]}"
        return 0
    fi

    info "Missing media tools: ${missing[*]}"
    if [ "${AUTO_INSTALL_TOOLS:-0}" = "1" ] && [ -n "$instal_cmd" ]; then
        info "Attempting to install missing tools: ${missing[*]}"
        $instal_cmd ${missing[*]} || warn "Automatic install failed; please install: ${missing[*]}"
    else
        info "To install missing tools, run:"
        if [ -n "$instal_cmd" ]; then
            echo "$instal_cmd ${missing[*]}"
        else
            echo "Install ${missing[*]} with your distro package manager (apt/dnf/pacman)"
        fi
        info "Or set AUTO_INSTALL_TOOLS=1 and re-run the installer to attempt auto-install"
    fi
}

write_web_control(){
    cat > "$BIN_DIR/xui_web_api.py" <<'PY'
#!/usr/bin/env python3
"""Minimal XUI web-control API."""
import http.server
import socketserver
import json
import os

XUI = os.path.expanduser('~/.xui')

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        # Simple health endpoint
        if self.path == '/status':
            res = {'status':'ok'}
            self.send_response(200)
            self.send_header('Content-Type','application/json')
            self.end_headers()
            self.wfile.write(json.dumps(res).encode())
            return
        if self.path == '/apps':
            apps = []
            try:
                apps = sorted(os.listdir(os.path.join(XUI, 'bin')))
            except Exception:
                pass
            self.send_response(200)
            self.send_header('Content-Type','application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'apps': apps}).encode())
            return
        return http.server.SimpleHTTPRequestHandler.do_GET(self)


class ReuseTCPServer(socketserver.TCPServer):
    allow_reuse_address = True


def serve(port=8020):
    with ReuseTCPServer(('127.0.0.1', port), Handler) as httpd:
        print(f'XUI web-control listening on 127.0.0.1:{port}')
        httpd.serve_forever()

if __name__=='__main__':
    try:
        port = int(os.environ.get('XUI_WEB_PORT', '8020'))
    except Exception:
        port = 8020
    serve(port)
PY
    chmod +x "$BIN_DIR/xui_web_api.py"

    cat > "$BIN_DIR/xui_web_control.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
ACTION=${1:-start}
PORT=${2:-8020}
PIDFILE="$HOME/.xui/data/web_api.pid"
LOGFILE="$HOME/.xui/logs/web_api.log"
mkdir -p "$HOME/.xui/data" "$HOME/.xui/logs"

is_running(){
  if [ -f "$PIDFILE" ]; then
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null
    return $?
  fi
  return 1
}

start_web(){
  if is_running; then
    echo "web-control already running (pid $(cat "$PIDFILE"))"
    return 0
  fi
  XUI_WEB_PORT="$PORT" nohup python3 "$HOME/.xui/bin/xui_web_api.py" >>"$LOGFILE" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 0.2
  if is_running; then
    echo "web-control started on http://127.0.0.1:$PORT (pid $(cat "$PIDFILE"))"
  else
    echo "web-control failed to start, check $LOGFILE"
    return 1
  fi
}

stop_web(){
  if ! is_running; then
    rm -f "$PIDFILE"
    echo "web-control is not running"
    return 0
  fi
  pid="$(cat "$PIDFILE")"
  kill "$pid" 2>/dev/null || true
  sleep 0.2
  kill -9 "$pid" 2>/dev/null || true
  rm -f "$PIDFILE"
  echo "web-control stopped"
}

status_web(){
  if is_running; then
    echo "running pid $(cat "$PIDFILE")"
  else
    echo "stopped"
    return 1
  fi
}

case "$ACTION" in
  start) start_web ;;
  stop) stop_web ;;
  restart) stop_web; start_web ;;
  status) status_web ;;
  *) echo "Usage: $0 {start|stop|restart|status} [port]"; exit 1 ;;
esac
BASH
    chmod +x "$BIN_DIR/xui_web_control.sh"
}

write_theme_toggle(){
    info "Writing theme toggle utility"
    cat > "$BIN_DIR/xui_theme.sh" <<'BASH'
#!/usr/bin/env bash
THEMEDIR="$HOME/.xui/data"
FILE="$THEMEDIR/theme.json"
mkdir -p "$THEMEDIR"
CUR=$(cat "$FILE" 2>/dev/null || echo '{"name":"default"}')
case ${1:-toggle} in
    toggle)
        NAME=$(python3 - <<PY
import json
f='$FILE'
try:
        d=json.load(open(f))
except Exception:
        d={'name':'default'}
n='dark' if d.get('name')=='default' else 'default'
print(n)
PY
)
        echo "{\"name\":\"$NAME\"}" > "$FILE"; echo "$NAME"; ;;
    set)
        echo "{\"name\":\"${2:-default}\"}" > "$FILE"; echo set;;
    *) echo "Usage: $0 {toggle|set <name>}"; exit 1;;
esac
BASH
    chmod +x "$BIN_DIR/xui_theme.sh"
}

write_volume_brightness_scripts(){
    info "Writing volume/brightness helper scripts"
    cat > "$BIN_DIR/xui_set_volume.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
V=${1:-50}
if command -v pactl >/dev/null 2>&1; then
    pactl set-sink-volume @DEFAULT_SINK@ ${V}%
else
    echo "pactl not available"
fi
SH
    chmod +x "$BIN_DIR/xui_set_volume.sh"

    cat > "$BIN_DIR/xui_set_brightness.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
V=${1:-50}
if command -v brightnessctl >/dev/null 2>&1; then
    brightnessctl set ${V}%
elif command -v xbacklight >/dev/null 2>&1; then
    xbacklight -set ${V}
else
    echo "brightnessctl/xbacklight not available"
fi
SH
    chmod +x "$BIN_DIR/xui_set_brightness.sh"
    info "Wrote $BIN_DIR/xui_set_volume.sh and xui_set_brightness.sh"
}

# Joy listener as standalone script (user systemd service will reference it)
write_joy_py(){
  info "Writing joy listener to $BIN_DIR/xui_joy_listener.py"
  cat > "$BIN_DIR/xui_joy_listener.py" <<'PY'
#!/usr/bin/env python3
"""Simple Joy listener: map event codes to xdotool keys
Runs as user service. Keeps minimal logic so dashboard can also run its own listener.
"""
import time, os, subprocess
try:
    from evdev import list_devices, InputDevice
except Exception:
    # evdev missing
    list_devices = lambda: []

KEYMAP = {
    # example mapping; device-specific codes vary
    '304':'Return', '305':'Escape', '16':'Left', '17':'Right', '103':'Up', '108':'Down'
}

def find_and_listen():
    for p in list_devices():
        try:
            d = InputDevice(p)
            if 'joystick' in d.name.lower() or 'gamepad' in d.name.lower() or 'joy' in d.name.lower():
                for ev in d.read_loop():
                    if ev.type == 1 and ev.value == 1:
                        k = KEYMAP.get(str(ev.code))
                        if k:
                            subprocess.run(['xdotool','key',k])
        except Exception:
            continue

if __name__ == '__main__':
    while True:
        try:
            find_and_listen()
        except Exception:
            time.sleep(2)
PY
  chmod +x "$BIN_DIR/xui_joy_listener.py"
}

# Create casino, runner, missions and store apps with GUI flows.
write_extras(){
  info "Writing casino, runner, missions, store and helper scripts"
  mkdir -p "$CASINO_DIR" "$GAMES_DIR" "$DATA_DIR" "$XUI_DIR/apps"

  # Seed core data files so apps work on first boot
  if [ ! -f "$DATA_DIR/saldo.json" ]; then
    cat > "$DATA_DIR/saldo.json" <<'JSON'
{"balance":250.0,"currency":"EUR"}
JSON
  fi
  if [ ! -f "$DATA_DIR/store.json" ]; then
    cat > "$DATA_DIR/store.json" <<'JSON'
{
  "items": [
    {"id":"theme_neon","name":"Theme Neon","price":25,"desc":"Tema visual neón"},
    {"id":"avatar_pack","name":"Avatar Pack","price":40,"desc":"Paquete de avatares"},
    {"id":"sound_pack","name":"Sound Pack","price":30,"desc":"Efectos y sonidos extra"},
    {"id":"bonus_credits","name":"Bonus Credits","price":60,"desc":"Créditos extra para minijuegos"},
    {"id":"runner_skin","name":"Runner Skin","price":20,"desc":"Skin para runner"}
  ]
}
JSON
  fi
  if [ ! -f "$DATA_DIR/missions.json" ]; then
    cat > "$DATA_DIR/missions.json" <<'JSON'
[
  {"id":"m1","title":"Lanzar Casino","desc":"Abre Casino una vez","done":false,"reward":10},
  {"id":"m2","title":"Completa una partida Runner","desc":"Juega Runner hasta game over","done":false,"reward":15},
  {"id":"m3","title":"Comprar en tienda","desc":"Compra un ítem en Store","done":false,"reward":8},
  {"id":"m4","title":"Revisar estado de compatibilidad","desc":"Abre Compat X86","done":false,"reward":6}
]
JSON
  fi
  if [ ! -f "$DATA_DIR/inventory.json" ]; then
    cat > "$DATA_DIR/inventory.json" <<'JSON'
{"items":[]}
JSON
  fi

  cat > "$BIN_DIR/xui_game_lib.py" <<'PY'
#!/usr/bin/env python3
import json
from pathlib import Path

DATA_HOME = Path.home() / '.xui' / 'data'
WALLET_FILE = DATA_HOME / 'saldo.json'
STORE_FILE = DATA_HOME / 'store.json'
MISSIONS_FILE = DATA_HOME / 'missions.json'
INVENTORY_FILE = DATA_HOME / 'inventory.json'


def _safe_read(path, default):
    try:
        return json.loads(Path(path).read_text())
    except Exception:
        return default


def _safe_write(path, data):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=2))


def ensure_wallet():
    DATA_HOME.mkdir(parents=True, exist_ok=True)
    if not WALLET_FILE.exists():
        _safe_write(WALLET_FILE, {'balance': 250.0, 'currency': 'EUR'})


def load_wallet():
    ensure_wallet()
    data = _safe_read(WALLET_FILE, {'balance': 250.0, 'currency': 'EUR'})
    try:
        bal = float(data.get('balance', 0.0))
    except Exception:
        bal = 0.0
    return {'balance': round(max(0.0, bal), 2), 'currency': data.get('currency', 'EUR')}


def get_balance():
    return load_wallet()['balance']


def set_balance(value):
    w = load_wallet()
    try:
        w['balance'] = round(max(0.0, float(value)), 2)
    except Exception:
        pass
    _safe_write(WALLET_FILE, w)
    return w['balance']


def change_balance(delta):
    w = load_wallet()
    try:
        w['balance'] = round(max(0.0, float(w.get('balance', 0.0)) + float(delta)), 2)
    except Exception:
        pass
    _safe_write(WALLET_FILE, w)
    return w['balance']


def load_store():
    data = _safe_read(STORE_FILE, {'items': []})
    if not isinstance(data, dict):
        return {'items': []}
    items = data.get('items', [])
    if not isinstance(items, list):
        items = []
    data['items'] = items
    return data


def save_missions(data):
    _safe_write(MISSIONS_FILE, data if isinstance(data, list) else [])


def load_missions():
    data = _safe_read(MISSIONS_FILE, [])
    return data if isinstance(data, list) else []


def load_inventory():
    data = _safe_read(INVENTORY_FILE, {'items': []})
    if not isinstance(data, dict):
        return {'items': []}
    items = data.get('items', [])
    if not isinstance(items, list):
        items = []
    data['items'] = items
    return data


def save_inventory(data):
    _safe_write(INVENTORY_FILE, data if isinstance(data, dict) else {'items': []})


def complete_mission(mission_id=None, title_contains=None):
    missions = load_missions()
    idx = -1
    for i, m in enumerate(missions):
        if mission_id is not None and str(m.get('id')) == str(mission_id):
            idx = i
            break
        if title_contains is not None and str(title_contains).lower() in str(m.get('title', '')).lower():
            idx = i
            break
    if idx < 0:
        return {'completed': False, 'reward': 0.0, 'balance': get_balance()}
    if missions[idx].get('done'):
        return {'completed': False, 'reward': 0.0, 'balance': get_balance()}
    reward = float(missions[idx].get('reward', 0))
    missions[idx]['done'] = True
    save_missions(missions)
    if reward > 0:
        change_balance(reward)
    return {'completed': True, 'reward': reward, 'balance': get_balance()}
PY
  chmod +x "$BIN_DIR/xui_game_lib.py"

  cat > "$CASINO_DIR/casino.py" <<'PY'
#!/usr/bin/env python3
import random
import sys
from pathlib import Path
from PyQt5 import QtWidgets, QtCore

sys.path.insert(0, str(Path.home() / '.xui' / 'bin'))
from xui_game_lib import get_balance, change_balance, ensure_wallet, complete_mission


RED_NUMBERS = {1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36}


class CasinoWindow(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()
        ensure_wallet()
        self.start_msg = 'Bienvenido al casino.'
        m = complete_mission(mission_id='m1')
        if m.get('completed'):
            self.start_msg = f"Bienvenido al casino. Mission +EUR {m.get('reward', 0):.2f}"
        self.setWindowTitle('XUI Casino')
        self.resize(860, 560)
        self._build()
        self.refresh_balance(self.start_msg)

    def _build(self):
        root = QtWidgets.QWidget()
        self.setCentralWidget(root)
        v = QtWidgets.QVBoxLayout(root)
        v.setContentsMargins(16, 16, 16, 16)
        v.setSpacing(12)

        self.balance_lbl = QtWidgets.QLabel()
        self.balance_lbl.setStyleSheet('font-size:24px; font-weight:700; color:#d8ffd8;')
        self.info_lbl = QtWidgets.QLabel()
        self.info_lbl.setStyleSheet('font-size:18px; color:#f0f7f0;')
        v.addWidget(self.balance_lbl)
        v.addWidget(self.info_lbl)

        tabs = QtWidgets.QTabWidget()
        tabs.addTab(self._slots_tab(), 'Slots')
        tabs.addTab(self._roulette_tab(), 'Roulette')
        tabs.addTab(self._blackjack_tab(), 'Blackjack')
        v.addWidget(tabs, 1)

        self.setStyleSheet('''
            QMainWindow { background:#13201b; color:#eef7ee; }
            QTabWidget::pane { border:1px solid #2a4738; background:#0f1a15; }
            QTabBar::tab { background:#1e3529; color:#e9f5e9; padding:8px 16px; }
            QTabBar::tab:selected { background:#2f9f49; color:#ffffff; font-weight:700; }
            QPushButton { background:#2ea84a; color:white; border:none; padding:8px 14px; border-radius:4px; }
            QPushButton:hover { background:#37bc55; }
            QSpinBox, QComboBox { background:#1d2a23; color:white; border:1px solid #3b5244; padding:4px; }
            QLabel#result { font-size:30px; font-weight:700; color:#f8fff8; }
        ''')

    def refresh_balance(self, text=''):
        self.balance_lbl.setText(f'Balance: EUR {get_balance():.2f}')
        self.info_lbl.setText(text)

    def _slots_tab(self):
        w = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(w)
        v.setContentsMargins(16, 16, 16, 16)
        v.setSpacing(12)

        self.slots_result = QtWidgets.QLabel('7 | BAR | CHERRY')
        self.slots_result.setObjectName('result')
        self.slots_result.setAlignment(QtCore.Qt.AlignCenter)

        row = QtWidgets.QHBoxLayout()
        self.slots_bet = QtWidgets.QSpinBox()
        self.slots_bet.setRange(1, 1000)
        self.slots_bet.setValue(10)
        spin_btn = QtWidgets.QPushButton('Spin')
        spin_btn.clicked.connect(self.play_slots)
        row.addWidget(QtWidgets.QLabel('Bet:'))
        row.addWidget(self.slots_bet)
        row.addWidget(spin_btn)
        row.addStretch(1)

        rules = QtWidgets.QLabel('3 iguales: x6 (x12 si es 7) | 2 iguales: x2')
        rules.setStyleSheet('font-size:16px; color:#d4e9d4;')

        v.addWidget(self.slots_result)
        v.addLayout(row)
        v.addWidget(rules)
        v.addStretch(1)
        return w

    def play_slots(self):
        bet = int(self.slots_bet.value())
        bal = get_balance()
        if bet <= 0 or bet > bal:
            self.refresh_balance('Apuesta inválida para el balance actual.')
            return
        symbols = ['7', 'BAR', 'CHERRY', 'BELL', 'X']
        reels = [random.choice(symbols) for _ in range(3)]
        self.slots_result.setText(' | '.join(reels))
        payout = 0
        if reels[0] == reels[1] == reels[2]:
            payout = bet * (12 if reels[0] == '7' else 6)
        elif len(set(reels)) == 2:
            payout = bet * 2
        delta = -bet + payout
        new_bal = change_balance(delta)
        if payout > 0:
            self.refresh_balance(f'Slots: +EUR {payout:.2f} (neto {delta:+.2f})')
        else:
            self.refresh_balance(f'Slots: -EUR {bet:.2f}')
        self.balance_lbl.setText(f'Balance: EUR {new_bal:.2f}')

    def _roulette_tab(self):
        w = QtWidgets.QWidget()
        g = QtWidgets.QGridLayout(w)
        g.setContentsMargins(16, 16, 16, 16)
        g.setHorizontalSpacing(10)
        g.setVerticalSpacing(12)

        self.roulette_bet = QtWidgets.QSpinBox()
        self.roulette_bet.setRange(1, 1000)
        self.roulette_bet.setValue(10)
        self.roulette_mode = QtWidgets.QComboBox()
        self.roulette_mode.addItems(['Red', 'Black', 'Even', 'Odd', 'Exact'])
        self.roulette_number = QtWidgets.QSpinBox()
        self.roulette_number.setRange(0, 36)
        self.roulette_number.setValue(7)
        self.roulette_result = QtWidgets.QLabel('Resultado: -')
        self.roulette_result.setStyleSheet('font-size:24px; font-weight:700;')
        play_btn = QtWidgets.QPushButton('Spin Roulette')
        play_btn.clicked.connect(self.play_roulette)

        g.addWidget(QtWidgets.QLabel('Bet:'), 0, 0)
        g.addWidget(self.roulette_bet, 0, 1)
        g.addWidget(QtWidgets.QLabel('Mode:'), 1, 0)
        g.addWidget(self.roulette_mode, 1, 1)
        g.addWidget(QtWidgets.QLabel('Exact number:'), 2, 0)
        g.addWidget(self.roulette_number, 2, 1)
        g.addWidget(play_btn, 3, 0, 1, 2)
        g.addWidget(self.roulette_result, 4, 0, 1, 2)
        g.setRowStretch(5, 1)
        return w

    def play_roulette(self):
        bet = int(self.roulette_bet.value())
        bal = get_balance()
        if bet <= 0 or bet > bal:
            self.refresh_balance('Apuesta inválida para roulette.')
            return
        mode = self.roulette_mode.currentText()
        result = random.randint(0, 36)
        color = 'Green' if result == 0 else ('Red' if result in RED_NUMBERS else 'Black')
        payout = 0

        if mode == 'Exact':
            if result == int(self.roulette_number.value()):
                payout = bet * 36
        elif mode == 'Red':
            if color == 'Red':
                payout = bet * 2
        elif mode == 'Black':
            if color == 'Black':
                payout = bet * 2
        elif mode == 'Even':
            if result != 0 and result % 2 == 0:
                payout = bet * 2
        elif mode == 'Odd':
            if result % 2 == 1:
                payout = bet * 2

        delta = -bet + payout
        new_bal = change_balance(delta)
        self.roulette_result.setText(f'Resultado: {result} ({color})')
        if payout > 0:
            self.refresh_balance(f'Roulette: +EUR {payout:.2f} (neto {delta:+.2f})')
        else:
            self.refresh_balance(f'Roulette: -EUR {bet:.2f}')
        self.balance_lbl.setText(f'Balance: EUR {new_bal:.2f}')

    def _blackjack_tab(self):
        w = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(w)
        v.setContentsMargins(16, 16, 16, 16)
        v.setSpacing(10)

        row = QtWidgets.QHBoxLayout()
        self.bj_bet = QtWidgets.QSpinBox()
        self.bj_bet.setRange(1, 1000)
        self.bj_bet.setValue(15)
        btn = QtWidgets.QPushButton('Play Hand')
        btn.clicked.connect(self.play_blackjack)
        row.addWidget(QtWidgets.QLabel('Bet:'))
        row.addWidget(self.bj_bet)
        row.addWidget(btn)
        row.addStretch(1)

        self.bj_result = QtWidgets.QLabel('Player: - | Dealer: -')
        self.bj_result.setStyleSheet('font-size:24px; font-weight:700;')
        rules = QtWidgets.QLabel('Win x2, Push devuelve apuesta, Bust pierde.')
        rules.setStyleSheet('font-size:16px; color:#d4e9d4;')
        v.addLayout(row)
        v.addWidget(self.bj_result)
        v.addWidget(rules)
        v.addStretch(1)
        return w

    def play_blackjack(self):
        bet = int(self.bj_bet.value())
        bal = get_balance()
        if bet <= 0 or bet > bal:
            self.refresh_balance('Apuesta inválida para blackjack.')
            return
        player = random.randint(14, 23)
        dealer = random.randint(14, 23)
        payout = 0
        msg = 'Empate'
        if player > 21:
            msg = 'Te pasaste'
            payout = 0
        elif dealer > 21 or player > dealer:
            msg = 'Ganaste'
            payout = bet * 2
        elif dealer == player:
            msg = 'Push'
            payout = bet
        else:
            msg = 'Perdiste'
            payout = 0
        delta = -bet + payout
        new_bal = change_balance(delta)
        self.bj_result.setText(f'Player: {player} | Dealer: {dealer} -> {msg}')
        self.refresh_balance(f'Blackjack neto: {delta:+.2f}')
        self.balance_lbl.setText(f'Balance: EUR {new_bal:.2f}')

    def keyPressEvent(self, e):
        if e.key() in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.close()
            return
        super().keyPressEvent(e)


def main():
    app = QtWidgets.QApplication(sys.argv)
    w = CasinoWindow()
    try:
        w.showFullScreen()
    except Exception:
        w.show()
    sys.exit(app.exec_())


if __name__ == '__main__':
    main()
PY
  chmod +x "$CASINO_DIR/casino.py"

  cat > "$GAMES_DIR/runner.py" <<'PY'
#!/usr/bin/env python3
import random
import sys
from pathlib import Path
from PyQt5 import QtWidgets, QtGui, QtCore

sys.path.insert(0, str(Path.home() / '.xui' / 'bin'))
from xui_game_lib import change_balance, get_balance, complete_mission


class RunnerGame(QtWidgets.QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle('XUI Runner')
        self.resize(920, 360)
        self.setFocusPolicy(QtCore.Qt.StrongFocus)
        self.ground = 290
        self.player_x = 80
        self.player_y = self.ground - 42
        self.player_w = 34
        self.player_h = 42
        self.vy = 0.0
        self.gravity = 0.85
        self.jump_v = -13.5
        self.obstacles = []
        self.spawn_tick = 0
        self.score = 0
        self.running = True

        self.timer = QtCore.QTimer(self)
        self.timer.timeout.connect(self.tick)
        self.timer.start(16)

    def tick(self):
        if not self.running:
            return
        self.score += 1
        self.spawn_tick += 1

        # Player physics
        self.vy += self.gravity
        self.player_y += self.vy
        max_y = self.ground - self.player_h
        if self.player_y >= max_y:
            self.player_y = max_y
            self.vy = 0.0

        # Obstacles
        if self.spawn_tick >= 48:
            self.spawn_tick = 0
            h = random.randint(28, 58)
            w = random.randint(18, 30)
            self.obstacles.append(QtCore.QRect(920, self.ground - h, w, h))

        speed = 7
        kept = []
        for r in self.obstacles:
            r.translate(-speed, 0)
            if r.right() > 0:
                kept.append(r)
        self.obstacles = kept

        # Collision
        player_rect = QtCore.QRect(int(self.player_x), int(self.player_y), self.player_w, self.player_h)
        for ob in self.obstacles:
            if player_rect.intersects(ob):
                self.end_game()
                return
        self.update()

    def end_game(self):
        self.running = False
        self.timer.stop()
        reward = max(1, self.score // 160)
        bal = change_balance(reward)
        m = complete_mission(mission_id='m2')
        extra = ''
        if m.get('completed'):
            bal = m.get('balance', bal)
            extra = f"\nMission reward: +{float(m.get('reward', 0)):.2f}"
        QtWidgets.QMessageBox.information(
            self,
            'Runner',
            f'Game Over\nScore: {self.score}\nReward: +{reward} credits{extra}\nBalance: EUR {bal:.2f}',
        )
        self.close()

    def keyPressEvent(self, e):
        if e.key() in (QtCore.Qt.Key_Space, QtCore.Qt.Key_Up):
            if self.player_y >= (self.ground - self.player_h - 0.5):
                self.vy = self.jump_v
        elif e.key() == QtCore.Qt.Key_Escape:
            self.close()
            return
        super().keyPressEvent(e)

    def paintEvent(self, _e):
        p = QtGui.QPainter(self)
        p.fillRect(self.rect(), QtGui.QColor('#101820'))
        p.fillRect(0, self.ground, self.width(), self.height() - self.ground, QtGui.QColor('#25353f'))

        # Player
        p.fillRect(
            QtCore.QRect(int(self.player_x), int(self.player_y), self.player_w, self.player_h),
            QtGui.QColor('#32c652')
        )

        # Obstacles
        p.setBrush(QtGui.QColor('#f5f5f5'))
        p.setPen(QtCore.Qt.NoPen)
        for ob in self.obstacles:
            p.drawRect(ob)

        p.setPen(QtGui.QColor('#eaf2f2'))
        p.setFont(QtGui.QFont('Sans Serif', 13, QtGui.QFont.Bold))
        p.drawText(14, 24, f'Score: {self.score}')
        p.drawText(14, 48, f'Balance: EUR {get_balance():.2f}')
        p.drawText(14, 72, 'SPACE/UP = jump | ESC = exit')
        p.end()


def main():
    app = QtWidgets.QApplication(sys.argv)
    w = RunnerGame()
    try:
        w.showFullScreen()
    except Exception:
        w.show()
    sys.exit(app.exec_())


if __name__ == '__main__':
    main()
PY
  chmod +x "$GAMES_DIR/runner.py"

  cat > "$GAMES_DIR/missions.py" <<'PY'
#!/usr/bin/env python3
import sys
from pathlib import Path
from PyQt5 import QtWidgets

sys.path.insert(0, str(Path.home() / '.xui' / 'bin'))
from xui_game_lib import load_missions, save_missions, change_balance, get_balance


class MissionsWindow(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle('XUI Missions')
        self.resize(760, 520)
        self.missions = []
        self._build()
        self.reload()

    def _build(self):
        root = QtWidgets.QWidget()
        self.setCentralWidget(root)
        v = QtWidgets.QVBoxLayout(root)
        v.setContentsMargins(16, 16, 16, 16)
        v.setSpacing(10)

        self.balance_lbl = QtWidgets.QLabel()
        self.balance_lbl.setStyleSheet('font-size:22px; font-weight:700;')
        self.listw = QtWidgets.QListWidget()
        self.listw.setStyleSheet('font-size:18px;')
        self.info_lbl = QtWidgets.QLabel()
        self.info_lbl.setStyleSheet('font-size:16px; color:#d7f0d7;')

        row = QtWidgets.QHBoxLayout()
        btn_complete = QtWidgets.QPushButton('Complete Selected')
        btn_reset = QtWidgets.QPushButton('Reset Missions')
        btn_close = QtWidgets.QPushButton('Close')
        btn_complete.clicked.connect(self.complete_selected)
        btn_reset.clicked.connect(self.reset_missions)
        btn_close.clicked.connect(self.close)
        row.addWidget(btn_complete)
        row.addWidget(btn_reset)
        row.addStretch(1)
        row.addWidget(btn_close)

        v.addWidget(self.balance_lbl)
        v.addWidget(self.listw, 1)
        v.addLayout(row)
        v.addWidget(self.info_lbl)

        self.setStyleSheet('''
            QMainWindow { background:#10181f; color:#f0f6f0; }
            QPushButton { background:#2ea84a; color:white; border:none; padding:7px 12px; border-radius:4px; }
            QPushButton:hover { background:#39bc57; }
        ''')

    def reload(self, msg=''):
        self.missions = load_missions()
        self.listw.clear()
        for m in self.missions:
            done = m.get('done', False)
            t = m.get('title', 'Mission')
            d = m.get('desc', '')
            r = m.get('reward', 0)
            prefix = '[DONE]' if done else '[TODO]'
            self.listw.addItem(f'{prefix} {t} (+{r}) - {d}')
        self.balance_lbl.setText(f'Balance: EUR {get_balance():.2f}')
        self.info_lbl.setText(msg)

    def complete_selected(self):
        idx = self.listw.currentRow()
        if idx < 0 or idx >= len(self.missions):
            self.reload('Selecciona una misión primero.')
            return
        mission = self.missions[idx]
        if mission.get('done'):
            self.reload('Esa misión ya estaba completada.')
            return
        reward = float(mission.get('reward', 0))
        mission['done'] = True
        self.missions[idx] = mission
        save_missions(self.missions)
        bal = change_balance(reward)
        self.reload(f"Misión completada: +{reward:.2f} | Balance EUR {bal:.2f}")

    def reset_missions(self):
        for i, m in enumerate(self.missions):
            m['done'] = False
            self.missions[i] = m
        save_missions(self.missions)
        self.reload('Misiones reiniciadas.')

    def keyPressEvent(self, e):
        if e.key() in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.close()
            return
        super().keyPressEvent(e)


def main():
    app = QtWidgets.QApplication(sys.argv)
    w = MissionsWindow()
    try:
        w.showFullScreen()
    except Exception:
        w.show()
    sys.exit(app.exec_())


if __name__ == '__main__':
    main()
PY
  chmod +x "$GAMES_DIR/missions.py"

  cat > "$GAMES_DIR/store.py" <<'PY'
#!/usr/bin/env python3
import sys
from pathlib import Path
from PyQt5 import QtWidgets

sys.path.insert(0, str(Path.home() / '.xui' / 'bin'))
from xui_game_lib import load_store, load_inventory, save_inventory, get_balance, change_balance, complete_mission


class StoreWindow(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle('XUI Store')
        self.resize(840, 560)
        self.store_data = {'items': []}
        self.inventory = {'items': []}
        self._build()
        self.reload()

    def _build(self):
        root = QtWidgets.QWidget()
        self.setCentralWidget(root)
        v = QtWidgets.QVBoxLayout(root)
        v.setContentsMargins(16, 16, 16, 16)
        v.setSpacing(10)

        self.balance_lbl = QtWidgets.QLabel()
        self.balance_lbl.setStyleSheet('font-size:22px; font-weight:700;')
        self.table = QtWidgets.QTableWidget(0, 3)
        self.table.setHorizontalHeaderLabels(['Item', 'Price', 'Description'])
        self.table.horizontalHeader().setStretchLastSection(True)
        self.table.setSelectionBehavior(QtWidgets.QAbstractItemView.SelectRows)
        self.table.setSelectionMode(QtWidgets.QAbstractItemView.SingleSelection)
        self.table.setEditTriggers(QtWidgets.QAbstractItemView.NoEditTriggers)
        self.table.setStyleSheet('font-size:16px;')
        self.info_lbl = QtWidgets.QLabel()
        self.info_lbl.setStyleSheet('font-size:16px; color:#d7f0d7;')

        row = QtWidgets.QHBoxLayout()
        buy_btn = QtWidgets.QPushButton('Buy Selected')
        inv_btn = QtWidgets.QPushButton('Show Inventory')
        close_btn = QtWidgets.QPushButton('Close')
        buy_btn.clicked.connect(self.buy_selected)
        inv_btn.clicked.connect(self.show_inventory)
        close_btn.clicked.connect(self.close)
        row.addWidget(buy_btn)
        row.addWidget(inv_btn)
        row.addStretch(1)
        row.addWidget(close_btn)

        v.addWidget(self.balance_lbl)
        v.addWidget(self.table, 1)
        v.addLayout(row)
        v.addWidget(self.info_lbl)

        self.setStyleSheet('''
            QMainWindow { background:#10181f; color:#f0f6f0; }
            QPushButton { background:#2ea84a; color:white; border:none; padding:7px 12px; border-radius:4px; }
            QPushButton:hover { background:#39bc57; }
        ''')

    def reload(self, msg=''):
        self.store_data = load_store()
        self.inventory = load_inventory()
        items = self.store_data.get('items', [])
        self.table.setRowCount(len(items))
        for i, item in enumerate(items):
            name = str(item.get('name', item.get('id', 'Item')))
            price = float(item.get('price', 0))
            desc = str(item.get('desc', ''))
            self.table.setItem(i, 0, QtWidgets.QTableWidgetItem(name))
            self.table.setItem(i, 1, QtWidgets.QTableWidgetItem(f'EUR {price:.2f}'))
            self.table.setItem(i, 2, QtWidgets.QTableWidgetItem(desc))
        self.balance_lbl.setText(f'Balance: EUR {get_balance():.2f}')
        self.info_lbl.setText(msg)

    def buy_selected(self):
        row = self.table.currentRow()
        items = self.store_data.get('items', [])
        if row < 0 or row >= len(items):
            self.reload('Selecciona un item para comprar.')
            return
        item = items[row]
        name = str(item.get('name', item.get('id', 'Item')))
        price = float(item.get('price', 0))
        bal = get_balance()
        if bal < price:
            self.reload('Saldo insuficiente.')
            return
        bal = change_balance(-price)
        inv = self.inventory.get('items', [])
        inv.append({'id': item.get('id', name), 'name': name, 'price': price})
        self.inventory['items'] = inv
        save_inventory(self.inventory)
        m = complete_mission(mission_id='m3')
        if m.get('completed'):
            bal = m.get('balance', bal)
            self.reload(f'Compra OK: {name} por EUR {price:.2f} | Mission +EUR {float(m.get("reward",0)):.2f} | Saldo EUR {bal:.2f}')
        else:
            self.reload(f'Compra OK: {name} por EUR {price:.2f} | Nuevo saldo EUR {bal:.2f}')

    def show_inventory(self):
        inv = self.inventory.get('items', [])
        if not inv:
            QtWidgets.QMessageBox.information(self, 'Inventory', 'No hay items comprados.')
            return
        lines = [f"{i+1}. {x.get('name','Item')} (EUR {float(x.get('price',0)):.2f})" for i, x in enumerate(inv)]
        QtWidgets.QMessageBox.information(self, 'Inventory', '\n'.join(lines))

    def keyPressEvent(self, e):
        if e.key() in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.close()
            return
        super().keyPressEvent(e)


def main():
    app = QtWidgets.QApplication(sys.argv)
    w = StoreWindow()
    try:
        w.showFullScreen()
    except Exception:
        w.show()
    sys.exit(app.exec_())


if __name__ == '__main__':
    main()
PY
  chmod +x "$GAMES_DIR/store.py"

  cat > "$BIN_DIR/xui_missions.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
exec "$HOME/.xui/bin/xui_python.sh" "$HOME/.xui/games/missions.py" "$@"
BASH
  chmod +x "$BIN_DIR/xui_missions.sh"

  cat > "$BIN_DIR/xui_store.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
exec "$HOME/.xui/bin/xui_python.sh" "$HOME/.xui/games/store.py" "$@"
BASH
  chmod +x "$BIN_DIR/xui_store.sh"

  cat > "$BIN_DIR/xui_balance.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
cmd=${1:-get}
amt=${2:-0}
python3 - "$cmd" "$amt" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path.home() / '.xui' / 'bin'))
from xui_game_lib import get_balance, set_balance, change_balance

cmd = sys.argv[1] if len(sys.argv) > 1 else 'get'
amt = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0

if cmd == 'get':
    print(get_balance())
elif cmd == 'add':
    print(change_balance(abs(amt)))
elif cmd == 'sub':
    bal = get_balance()
    if bal < amt:
        raise SystemExit(1)
    print(change_balance(-abs(amt)))
elif cmd == 'set':
    print(set_balance(amt))
else:
    print('Usage: xui_balance.sh {get|add|sub|set} [amount]')
    raise SystemExit(1)
PY
BASH
  chmod +x "$BIN_DIR/xui_balance.sh"

  cat > "$BIN_DIR/xui_mission_mark.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
mid=${1:-}
title=${2:-}
if [ -z "$mid" ] && [ -z "$title" ]; then
  echo "Usage: $0 <mission_id> [title_contains]"
  exit 1
fi
python3 - "$mid" "$title" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path.home() / '.xui' / 'bin'))
from xui_game_lib import complete_mission
mid = sys.argv[1] if len(sys.argv) > 1 else None
mid = mid if mid else None
title = sys.argv[2] if len(sys.argv) > 2 else None
title = title if title else None
r = complete_mission(mission_id=mid, title_contains=title)
if r.get('completed'):
    print(f"mission completed (+{float(r.get('reward',0)):.2f}) balance={float(r.get('balance',0)):.2f}")
else:
    print("mission unchanged")
PY
BASH
  chmod +x "$BIN_DIR/xui_mission_mark.sh"
}

# Systemd user units and autostart wrapper
write_systemd_and_autostart(){
  info "Creating systemd user units and autostart wrapper"
  cat > "$SYSTEMD_USER_DIR/xui-dashboard.service" <<UNIT
[Unit]
Description=XUI Dashboard (user)

After=graphical-session.target

[Service]
Type=simple
ExecStart=%h/.xui/bin/xui_startup_and_dashboard.sh
# Ensure a display and runtime dir are available for GUI startup under systemd --user
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/%U
Restart=on-failure

[Install]
WantedBy=default.target
UNIT

  cat > "$SYSTEMD_USER_DIR/xui-joy.service" <<UNIT
[Unit]
Description=XUI Joy Listener (user)

[Service]
Type=simple
ExecStart=%h/.xui/bin/xui_joy_listener.py
Restart=on-failure

[Install]
WantedBy=default.target
UNIT

  cat > "$BIN_DIR/xui_first_setup.py" <<'PY'
#!/usr/bin/env python3
import json
import re
import time
from pathlib import Path
from PyQt5 import QtWidgets, QtCore

XUI_HOME = Path.home() / '.xui'
DATA_HOME = XUI_HOME / 'data'
PROFILE_FILE = DATA_HOME / 'profile.json'
SETUP_FILE = DATA_HOME / 'setup_state.json'
UI_FILE = DATA_HOME / 'ui_settings.json'


def safe_json_read(path, default):
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except Exception:
        return default


def safe_json_write(path, data):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding='utf-8')


class XboxSetup(QtWidgets.QDialog):
    def __init__(self):
        super().__init__()
        self.setWindowTitle('XUI First Setup')
        self.resize(1100, 680)
        self._build()
        self._load_existing()
        self._sync_buttons()

    def _build(self):
        self.setStyleSheet('''
            QDialog {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #1f2630, stop:0.45 #29323e, stop:1 #10161d);
                color:#eef4f8;
            }
            QFrame#panel {
                background:rgba(4,10,18,0.82);
                border:2px solid rgba(130,190,255,0.3);
                border-radius:10px;
            }
            QLabel#title {
                font-size:40px;
                font-weight:800;
                color:#f4f8fb;
            }
            QLabel#hint {
                font-size:18px;
                color:rgba(236,243,247,0.78);
            }
            QLabel#section {
                font-size:30px;
                font-weight:760;
                color:#f0f6fa;
            }
            QLineEdit, QComboBox {
                background:#0f1a27;
                border:1px solid #2f4258;
                border-radius:4px;
                color:#f1f8fc;
                padding:8px;
                font-size:18px;
            }
            QCheckBox {
                font-size:18px;
                color:#e8f0f5;
            }
            QPushButton {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #31d75a, stop:1 #23b545);
                border:1px solid rgba(255,255,255,0.2);
                color:#efffee;
                padding:10px 18px;
                font-size:18px;
                font-weight:760;
                min-width:120px;
            }
            QPushButton:disabled {
                background:#40505f;
                color:#9daab5;
            }
        ''')
        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(22, 22, 22, 22)

        panel = QtWidgets.QFrame()
        panel.setObjectName('panel')
        outer.addWidget(panel, 1)
        root = QtWidgets.QVBoxLayout(panel)
        root.setContentsMargins(24, 20, 24, 18)
        root.setSpacing(14)

        top = QtWidgets.QVBoxLayout()
        title = QtWidgets.QLabel('xbox 360 style setup')
        title.setObjectName('title')
        hint = QtWidgets.QLabel('Configure your gamertag and profile before entering dashboard')
        hint.setObjectName('hint')
        top.addWidget(title)
        top.addWidget(hint)
        root.addLayout(top)

        self.stack = QtWidgets.QStackedWidget()
        root.addWidget(self.stack, 1)

        self._build_page_intro()
        self._build_page_account()
        self._build_page_prefs()

        nav = QtWidgets.QHBoxLayout()
        self.btn_back = QtWidgets.QPushButton('Back')
        self.btn_next = QtWidgets.QPushButton('Next')
        self.btn_finish = QtWidgets.QPushButton('Finish')
        self.btn_cancel = QtWidgets.QPushButton('Skip')
        self.btn_back.clicked.connect(self._go_back)
        self.btn_next.clicked.connect(self._go_next)
        self.btn_finish.clicked.connect(self._finish)
        self.btn_cancel.clicked.connect(self.reject)
        nav.addWidget(self.btn_cancel)
        nav.addStretch(1)
        nav.addWidget(self.btn_back)
        nav.addWidget(self.btn_next)
        nav.addWidget(self.btn_finish)
        root.addLayout(nav)

    def _build_page_intro(self):
        w = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(w)
        v.setContentsMargins(0, 6, 0, 0)
        v.setSpacing(14)
        s = QtWidgets.QLabel('Welcome')
        s.setObjectName('section')
        t1 = QtWidgets.QLabel('This first setup prepares your profile and sign-in identity.')
        t1.setObjectName('hint')
        t2 = QtWidgets.QLabel('Press Next to configure gamertag, region and startup preferences.')
        t2.setObjectName('hint')
        t2.setWordWrap(True)
        v.addWidget(s)
        v.addWidget(t1)
        v.addWidget(t2)
        v.addStretch(1)
        self.stack.addWidget(w)

    def _build_page_account(self):
        w = QtWidgets.QWidget()
        f = QtWidgets.QFormLayout(w)
        f.setContentsMargins(0, 6, 0, 0)
        f.setVerticalSpacing(12)
        f.setHorizontalSpacing(18)
        s = QtWidgets.QLabel('Account')
        s.setObjectName('section')
        self.ed_gamertag = QtWidgets.QLineEdit()
        self.ed_gamertag.setMaxLength(15)
        self.ed_gamertag.setPlaceholderText('Player1')
        self.ed_motto = QtWidgets.QLineEdit()
        self.ed_motto.setMaxLength(40)
        self.ed_motto.setPlaceholderText('Ready to play')
        self.cb_region = QtWidgets.QComboBox()
        self.cb_region.addItems(['LATAM', 'USA', 'EU', 'JP', 'OTHER'])
        self.chk_signed = QtWidgets.QCheckBox('Sign in automatically')
        self.chk_signed.setChecked(True)
        f.addRow(s)
        f.addRow('Gamertag', self.ed_gamertag)
        f.addRow('Motto', self.ed_motto)
        f.addRow('Region', self.cb_region)
        f.addRow('', self.chk_signed)
        self.stack.addWidget(w)

    def _build_page_prefs(self):
        w = QtWidgets.QWidget()
        f = QtWidgets.QFormLayout(w)
        f.setContentsMargins(0, 6, 0, 0)
        f.setVerticalSpacing(12)
        f.setHorizontalSpacing(18)
        s = QtWidgets.QLabel('Preferences')
        s.setObjectName('section')
        self.cb_accent = QtWidgets.QComboBox()
        self.cb_accent.addItems(['Green', 'Blue', 'Orange', 'White'])
        self.chk_startup_media = QtWidgets.QCheckBox('Enable startup media (mp4/mp3)')
        self.chk_startup_media.setChecked(True)
        self.chk_autostart = QtWidgets.QCheckBox('Start dashboard automatically at login')
        self.chk_autostart.setChecked(True)
        self.chk_autostart.setEnabled(False)
        self.lbl_note = QtWidgets.QLabel('Autostart is configured by installer for every login session.')
        self.lbl_note.setObjectName('hint')
        self.lbl_note.setWordWrap(True)
        f.addRow(s)
        f.addRow('Accent', self.cb_accent)
        f.addRow('', self.chk_startup_media)
        f.addRow('', self.chk_autostart)
        f.addRow('', self.lbl_note)
        self.stack.addWidget(w)

    def _load_existing(self):
        profile = safe_json_read(PROFILE_FILE, {})
        ui = safe_json_read(UI_FILE, {})
        self.ed_gamertag.setText(str(profile.get('gamertag', 'Player1')))
        self.ed_motto.setText(str(profile.get('motto', '')))
        region = str(profile.get('region', 'LATAM')).upper()
        idx = self.cb_region.findText(region)
        if idx >= 0:
            self.cb_region.setCurrentIndex(idx)
        accent = str(ui.get('accent', 'Green'))
        idx = self.cb_accent.findText(accent)
        if idx >= 0:
            self.cb_accent.setCurrentIndex(idx)
        self.chk_signed.setChecked(bool(profile.get('signed_in', False)))
        self.chk_startup_media.setChecked(bool(ui.get('startup_media', True)))

    def _sync_buttons(self):
        idx = self.stack.currentIndex()
        last = self.stack.count() - 1
        self.btn_back.setEnabled(idx > 0)
        self.btn_next.setVisible(idx < last)
        self.btn_finish.setVisible(idx == last)

    def _go_back(self):
        self.stack.setCurrentIndex(max(0, self.stack.currentIndex() - 1))
        self._sync_buttons()

    def _go_next(self):
        if self.stack.currentIndex() == 1 and not self._valid_gamertag():
            QtWidgets.QMessageBox.warning(self, 'Gamertag', 'Use 3-15 chars: letters, numbers, space, _ or -')
            return
        self.stack.setCurrentIndex(min(self.stack.count() - 1, self.stack.currentIndex() + 1))
        self._sync_buttons()

    def _valid_gamertag(self):
        gt = self.ed_gamertag.text().strip()
        return bool(re.fullmatch(r'[A-Za-z0-9 _-]{3,15}', gt))

    def _finish(self):
        if not self._valid_gamertag():
            QtWidgets.QMessageBox.warning(self, 'Gamertag', 'Use 3-15 chars: letters, numbers, space, _ or -')
            self.stack.setCurrentIndex(1)
            self._sync_buttons()
            return
        gamertag = self.ed_gamertag.text().strip()
        profile = safe_json_read(PROFILE_FILE, {})
        profile['gamertag'] = gamertag
        profile['motto'] = self.ed_motto.text().strip()
        profile['region'] = self.cb_region.currentText().strip()
        profile['signed_in'] = bool(self.chk_signed.isChecked())
        profile['updated_at'] = time.time()
        safe_json_write(PROFILE_FILE, profile)

        ui = safe_json_read(UI_FILE, {})
        ui['accent'] = self.cb_accent.currentText().strip()
        ui['startup_media'] = bool(self.chk_startup_media.isChecked())
        ui['autostart'] = True
        ui['updated_at'] = time.time()
        safe_json_write(UI_FILE, ui)

        state = {
            'completed': True,
            'completed_at': time.time(),
            'gamertag': gamertag,
            'version': 1,
        }
        safe_json_write(SETUP_FILE, state)
        self.accept()


def main():
    DATA_HOME.mkdir(parents=True, exist_ok=True)
    app = QtWidgets.QApplication([])
    app.setApplicationName('XUI First Setup')
    dlg = XboxSetup()
    try:
        dlg.showFullScreen()
    except Exception:
        dlg.show()
    app.exec_()


if __name__ == '__main__':
    main()
PY
  chmod +x "$BIN_DIR/xui_first_setup.py"

  cat > "$BIN_DIR/xui_start.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
exec "$HOME/.xui/bin/xui_startup_and_dashboard.sh"
BASH
  chmod +x "$BIN_DIR/xui_start.sh"

  cat > "$AUTOSTART_DIR/xui-dashboard.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=XUI Dashboard
Exec=$BIN_DIR/xui_startup_and_dashboard.sh
Icon=$ASSETS_DIR/logo.png
Terminal=false
StartupNotify=false
X-GNOME-Autostart-enabled=true
Hidden=false
DESK

# Ensure assets/logo.png exists: prefer installer-provided logo in script dir, else try to generate a placeholder with Pillow
mkdir -p "$ASSETS_DIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# --- Embedded asset blobs (replace placeholders with actual base64 to embed files) ---
# To embed files, replace the placeholder values below with the base64 contents (no newlines required).
# Example (posix):
#   base64 -w0 logo.png | sed 's/^/"/' | sed 's/$/"/' >> xui8.5.sh (insert between the triple quotes)
EMBED_LOGO_B64="$(cat <<'B64'
iVBORw0KGgoAAAANSUhEUgAAAwAAAAQACAIAAABv3i4WAAAgAElEQVR4nOydd3wcxZ3/3+u
7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u
7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7v8n8z8z8z8z8z8z8z8z8z8z8z8z
8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8
z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z
8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8
z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z8z
...REDACTED_FOR_BREVITY...
B64
 )"
EMBED_LOGO1_B64="__LOGO1_B64_PLACEHOLDER__"
EMBED_LOGO2_B64="__LOGO2_B64_PLACEHOLDER__"
EMBED_STARTUP_MP4_B64="__MP4_B64_PLACEHOLDER__"
EMBED_STARTUP_MP3_B64="__MP3_B64_PLACEHOLDER__"

# Decode embedded blobs only if explicitly enabled to avoid invalid-placeholder noise
if [ "${XUI_USE_EMBEDDED_ASSETS:-0}" = "1" ]; then
if [ -n "$EMBED_LOGO_B64" ] && [ "$EMBED_LOGO_B64" != "__LOGO_B64_PLACEHOLDER__" ]; then
    echo "$EMBED_LOGO_B64" | base64 -d > "$ASSETS_DIR/logo.png" 2>/dev/null || true
    [ -f "$ASSETS_DIR/logo.png" ] && info "Wrote embedded logo to $ASSETS_DIR/logo.png"
fi
if [ -n "$EMBED_LOGO1_B64" ] && [ "$EMBED_LOGO1_B64" != "__LOGO1_B64_PLACEHOLDER__" ]; then
    echo "$EMBED_LOGO1_B64" | base64 -d > "$ASSETS_DIR/logo1.png" 2>/dev/null || true
    [ -f "$ASSETS_DIR/logo1.png" ] && info "Wrote embedded logo1 to $ASSETS_DIR/logo1.png"
fi
if [ -n "$EMBED_LOGO2_B64" ] && [ "$EMBED_LOGO2_B64" != "__LOGO2_B64_PLACEHOLDER__" ]; then
    echo "$EMBED_LOGO2_B64" | base64 -d > "$ASSETS_DIR/logo2.png" 2>/dev/null || true
    [ -f "$ASSETS_DIR/logo2.png" ] && info "Wrote embedded logo2 to $ASSETS_DIR/logo2.png"
fi
if [ -n "$EMBED_STARTUP_MP4_B64" ] && [ "$EMBED_STARTUP_MP4_B64" != "__MP4_B64_PLACEHOLDER__" ]; then
    echo "$EMBED_STARTUP_MP4_B64" | base64 -d > "$ASSETS_DIR/startup.mp4" 2>/dev/null || true
    [ -f "$ASSETS_DIR/startup.mp4" ] && info "Wrote embedded startup.mp4 to $ASSETS_DIR/startup.mp4"
fi
if [ -n "$EMBED_STARTUP_MP3_B64" ] && [ "$EMBED_STARTUP_MP3_B64" != "__MP3_B64_PLACEHOLDER__" ]; then
    echo "$EMBED_STARTUP_MP3_B64" | base64 -d > "$ASSETS_DIR/startup.mp3" 2>/dev/null || true
    [ -f "$ASSETS_DIR/startup.mp3" ] && info "Wrote embedded startup.mp3 to $ASSETS_DIR/startup.mp3"
fi
fi
if [ -f "$SCRIPT_DIR/logo.png" ]; then
    cp "$SCRIPT_DIR/logo.png" "$ASSETS_DIR/logo.png"
    info "Copied installer logo to $ASSETS_DIR/logo.png"
else
    if command -v python3 >/dev/null 2>&1; then
        python3 - <<'PY' || true
try:
    from PIL import Image, ImageDraw, ImageFont
    import os
    out=os.path.expanduser('~/.xui/assets/logo.png')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    im=Image.new('RGBA',(512,512),(12,84,166,255))
    d=ImageDraw.Draw(im)
    try:
        f=ImageFont.truetype('DejaVuSans-Bold.ttf',72)
    except Exception:
        f=None
    text='XGUI'
    w,h=d.textsize(text,font=f)
    d.text(((512-w)/2,(512-h)/2),text,fill=(255,255,255,255),font=f)
    im.save(out)
    print('logo_generated')
except Exception:
    pass
PY
        info "Generated placeholder logo at $ASSETS_DIR/logo.png (if Pillow available)"
    else
        warn "No installer logo found and python3 not available to generate placeholder logo. Place $SCRIPT_DIR/logo.png manually into the installer directory."
    fi
fi

# Generate placeholder exit icon if missing
if [ ! -f "$ASSETS_DIR/Salir al escritorio.png" ]; then
    if command -v python3 >/dev/null 2>&1; then
        python3 - <<'PY' || true
try:
    from PIL import Image, ImageDraw, ImageFont
    import os
    out=os.path.expanduser('~/.xui/assets/Salir al escritorio.png')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    im=Image.new('RGBA',(320,180),(12,84,166,255))
    d=ImageDraw.Draw(im)
    try:
        f=ImageFont.truetype('DejaVuSans-Bold.ttf',28)
    except Exception:
        f=None
    txt='Salir'
    w,h=d.textsize(txt,font=f)
    d.text(((320-w)/2,(180-h)/2),txt,fill=(255,255,255,255),font=f)
    im.save(out)
    print('exit_icon_generated')
except Exception:
    pass
PY
    fi
fi

# Copy optional startup video and sound if provided next to the installer
# Also copy optional installer images if present (applogo/bootlogo)
if [ -f "$SCRIPT_DIR/applogo.png" ]; then
    cp "$SCRIPT_DIR/applogo.png" "$ASSETS_DIR/logo.png"
    info "Copied applogo.png to $ASSETS_DIR/logo.png"
fi
if [ -f "$SCRIPT_DIR/bootlogo.png" ]; then
    cp "$SCRIPT_DIR/bootlogo.png" "$ASSETS_DIR/logo1.png"
    info "Copied bootlogo.png to $ASSETS_DIR/logo1.png"
fi
if [ -f "$SCRIPT_DIR/startup.mp4" ]; then
    cp "$SCRIPT_DIR/startup.mp4" "$ASSETS_DIR/startup.mp4"
    info "Copied startup video to $ASSETS_DIR/startup.mp4"
fi
if [ -f "$SCRIPT_DIR/startup.mp3" ]; then
    cp "$SCRIPT_DIR/startup.mp3" "$ASSETS_DIR/startup.mp3"
    info "Copied startup sound to $ASSETS_DIR/startup.mp3"
fi

# Copy any other mp3 assets from installer dir into assets (click, hover, achievements, etc.)
for f in "$SCRIPT_DIR"/*.mp3; do
    if [ -f "$f" ]; then
        cp "$f" "$ASSETS_DIR/" && info "Copied $(basename "$f") to $ASSETS_DIR/"
    fi
done

# Create a manifest of assets installed
mkdir -p "$ASSETS_DIR"
# Try to convert PNG images to WebP (use cwebp if available, else Pillow)
if command -v cwebp >/dev/null 2>&1; then
  for p in "$ASSETS_DIR"/*.png; do
    [ -f "$p" ] || continue
    outp="${p%.*}.webp"
    cwebp -q 80 "$p" -o "$outp" >/dev/null 2>&1 || true
  done
elif command -v python3 >/dev/null 2>&1; then
  python3 - <<PY || true
import os
from pathlib import Path
try:
    from PIL import Image
except Exception:
    Image = None
ad = Path.home()/'.xui'/'assets'
if Image is not None:
    for p in ad.glob('*.png'):
        out = p.with_suffix('.webp')
        try:
            img = Image.open(p).convert('RGBA')
            img.save(out, 'WEBP', quality=80)
        except Exception:
            pass
PY
fi

# Generate manifest listing assets; prefer .webp when present (dashboard will try webp first)
python3 - <<PY || true
import os, json
ad = os.path.expanduser('~/.xui/assets')
files = []
names = sorted(os.listdir(ad))
seen = set()
for fn in names:
    base, ext = os.path.splitext(fn)
    if base in seen:
        continue
    # prefer webp over png
    if os.path.exists(os.path.join(ad, base + '.webp')):
        files.append(base + '.webp')
        seen.add(base)
    elif os.path.exists(os.path.join(ad, base + '.png')):
        files.append(base + '.png')
        seen.add(base)
    else:
        files.append(fn)
        seen.add(base)
out = {'assets': files}
with open(os.path.join(ad,'manifest.json'),'w') as fh:
    json.dump(out, fh, indent=2)
print('manifest_written')
PY
info "Wrote $ASSETS_DIR/manifest.json"

# Ensure applogo and bootlogo are present in assets (already handled above if provided),
# and create a startup wrapper that will play startup.mp3 & startup.mp4 and show bootlogo.png if needed
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/xui_startup_and_dashboard.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ASSETS_DIR="$HOME/.xui/assets"
DASH_SCRIPT="$HOME/.xui/dashboard/pyqt_dashboard_improved.py"
SETUP_SCRIPT="$HOME/.xui/bin/xui_first_setup.py"
SETUP_STATE="$HOME/.xui/data/setup_state.json"
PY_RUNNER="$HOME/.xui/bin/xui_python.sh"

info(){ echo -e "\e[34m[INFO]\e[0m $*"; }
warn(){ echo -e "\e[33m[WARN]\e[0m $*" >&2; }

run_python(){
    local target="$1"
    if [ -x "$PY_RUNNER" ]; then
        "$PY_RUNNER" "$target"
    else
        python3 "$target"
    fi
}

mkdir -p "$HOME/.xui/data" "$HOME/.xui/logs" "$ASSETS_DIR"

# Run first setup wizard once (or force with XUI_FORCE_SETUP=1)
if [ "${XUI_FORCE_SETUP:-0}" = "1" ] || [ ! -s "$SETUP_STATE" ]; then
    if [ -f "$SETUP_SCRIPT" ]; then
        info "Running first setup wizard"
        run_python "$SETUP_SCRIPT" || warn "First setup ended with non-zero status"
    else
        warn "Setup wizard not found: $SETUP_SCRIPT"
    fi
fi

# Helper to start audio in background using available players
start_audio_bg(){
    local file="$1"
    if [ ! -f "$file" ]; then return 1; fi
    if command -v mpv >/dev/null 2>&1; then
        mpv --no-terminal --really-quiet "$file" &
        echo $!
    elif command -v ffplay >/dev/null 2>&1; then
        ffplay -nodisp -autoexit -loglevel quiet "$file" &
        echo $!
    elif command -v paplay >/dev/null 2>&1; then
        paplay "$file" &
        echo $!
    elif command -v aplay >/dev/null 2>&1; then
        # aplay is blocking, so run in background
        aplay "$file" &
        echo $!
    elif command -v ffmpeg >/dev/null 2>&1; then
        # use ffmpeg to play audio via ffplay-like behaviour
        ffmpeg -hide_banner -loglevel error -i "$file" -f alsa default &
        echo $!
    else
        warn "No compatible audio player found for $file"
        return 1
    fi
}

# Helper to play video (blocking) using mpv or ffplay
play_video(){
    local file="$1"
    if [ ! -f "$file" ]; then return 1; fi
    if command -v mpv >/dev/null 2>&1; then
        mpv --no-terminal --really-quiet --fullscreen "$file"
        return $?
    elif command -v ffplay >/dev/null 2>&1; then
        ffplay -autoexit -fs -loglevel quiet "$file"
        return $?
    else
        warn "No video player found for $file"
        return 1
    fi
}

# Show an image (blocking until killed) using ffplay/mpv or a small python fallback
show_image_blocking_bg(){
    local file="$1"
    if [ ! -f "$file" ]; then return 1; fi
    if command -v mpv >/dev/null 2>&1; then
        mpv --no-terminal --really-quiet --fullscreen --loop-file=inf "$file" &
        echo $!
    elif command -v ffplay >/dev/null 2>&1; then
        ffplay -loop 0 -loglevel quiet "$file" &
        echo $!
    elif command -v python3 >/dev/null 2>&1; then
        # Simple Tkinter display
        python3 - <<PY &
import sys, time
from PIL import Image, ImageTk
try:
    import tkinter as tk
    root = tk.Tk()
    root.attributes('-fullscreen', True)
    img = Image.open(sys.argv[1])
    w,h = root.winfo_screenwidth(), root.winfo_screenheight()
    img = img.resize((w,h), Image.LANCZOS)
    photo = ImageTk.PhotoImage(img)
    label = tk.Label(root, image=photo)
    label.pack()
    root.mainloop()
except Exception:
    pass
PY
        echo $!
    else
        warn "No method to show image $file"
        return 1
    fi
}

# Start startup audio in background if available
startup_audio_pid=0
if [ -f "$ASSETS_DIR/startup.mp3" ]; then
    pid=$(start_audio_bg "$ASSETS_DIR/startup.mp3" || true)
    startup_audio_pid=${pid:-0}
    if [ "$startup_audio_pid" -ne 0 ]; then
        info "Started startup audio (pid=$startup_audio_pid)"
    fi
fi

# Play startup video (blocking) if present
if [ -f "$ASSETS_DIR/startup.mp4" ]; then
    info "Playing startup video"
    play_video "$ASSETS_DIR/startup.mp4" || true
fi

# If the audio is still running after the video ends, show bootlogo.png until audio stops
if [ "$startup_audio_pid" -ne 0 ] && kill -0 "$startup_audio_pid" >/dev/null 2>&1; then
    if [ -f "$ASSETS_DIR/bootlogo.png" ]; then
        info "Displaying bootlogo while audio finishes"
        img_pid=$(show_image_blocking_bg "$ASSETS_DIR/bootlogo.png" || true)
        # Poll until audio process exits
        while kill -0 "$startup_audio_pid" >/dev/null 2>&1; do
            sleep 0.5
        done
        # kill image display
        if [ -n "${img_pid:-}" ] && kill -0 "$img_pid" >/dev/null 2>&1; then
            kill "$img_pid" || true
        fi
    else
        # no bootlogo available; just wait for audio to finish
        while kill -0 "$startup_audio_pid" >/dev/null 2>&1; do
            sleep 0.5
        done
    fi
fi

# Finally start the dashboard
info "Launching dashboard"
if [ ! -f "$DASH_SCRIPT" ]; then
    warn "Dashboard script not found: $DASH_SCRIPT"
    exit 1
fi
if [ -x "$PY_RUNNER" ]; then
    exec "$PY_RUNNER" "$DASH_SCRIPT"
fi
exec python3 "$DASH_SCRIPT"
SH
chmod +x "$BIN_DIR/xui_startup_and_dashboard.sh"


# If startup media not provided, try to generate them from the embedded/copyed logo using ffmpeg (best-effort)
if [ ! -f "$ASSETS_DIR/startup.mp4" ] && command -v ffmpeg >/dev/null 2>&1 && [ -f "$ASSETS_DIR/logo.png" ]; then
    info "Generating $ASSETS_DIR/startup.mp4 from logo (ffmpeg detected)"
    ffmpeg -y -loop 1 -i "$ASSETS_DIR/logo.png" -c:v libx264 -t 3 -pix_fmt yuv420p "$ASSETS_DIR/startup.mp4" >/dev/null 2>&1 || warn "ffmpeg failed to generate startup.mp4"
fi

if [ ! -f "$ASSETS_DIR/startup.mp3" ] && command -v ffmpeg >/dev/null 2>&1; then
    info "Generating $ASSETS_DIR/startup.mp3 (3s sine tone)"
    ffmpeg -y -f lavfi -i "sine=frequency=440:duration=3" -c:a libmp3lame -q:a 4 "$ASSETS_DIR/startup.mp3" >/dev/null 2>&1 || warn "ffmpeg failed to generate startup.mp3"
fi
}

# Write embedded enable-autostart helper into $BIN_DIR
write_enable_autostart_script(){
        mkdir -p "$BIN_DIR"
        cat > "$BIN_DIR/xui_enable_autostart.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

# Installs autostart for XUI PyQt dashboard:
# - copies .desktop to ~/.config/autostart
# - installs systemd --user unit and enables it
# Run as the target user (not root). If you want system-wide boot before login you'll need a different approach.

XUI_HOME="$HOME/.xui"
AUTOSTART_DIR="$HOME/.config/autostart"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
DESKTOP_FILE_NAME="xui-dashboard.desktop"
SERVICE_NAME="xui-dashboard.service"
START_WRAPPER="$XUI_HOME/bin/xui_startup_and_dashboard.sh"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

mkdir -p "$AUTOSTART_DIR"
mkdir -p "$SYSTEMD_USER_DIR"

# Write .desktop (safe overwrite)
cat > "$AUTOSTART_DIR/$DESKTOP_FILE_NAME" <<EOF
[Desktop Entry]
Type=Application
Name=XUI Dashboard
Comment=Start XUI fullscreen dashboard
Exec=$START_WRAPPER
Terminal=false
X-GNOME-Autostart-enabled=true
Hidden=false
NoDisplay=false
Categories=Utility;
EOF

# Write systemd user service
cat > "$SYSTEMD_USER_DIR/$SERVICE_NAME" <<EOF
[Unit]
Description=XUI GUI Dashboard (user service)
After=graphical-session.target

[Service]
Type=simple
ExecStart=$START_WRAPPER
Restart=on-failure
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=$RUNTIME_DIR

[Install]
WantedBy=default.target
EOF

# Reload user systemd and enable service
systemctl --user daemon-reload
systemctl --user enable --now "$SERVICE_NAME" || {
    echo "Failed to enable systemd user service; you can enable it with: systemctl --user enable --now $SERVICE_NAME"
}

# Feedback
echo "Installed autostart .desktop to $AUTOSTART_DIR/$DESKTOP_FILE_NAME"
echo "Installed systemd user unit to $SYSTEMD_USER_DIR/$SERVICE_NAME (enabled)."

echo "Note: systemd user services run after you log in. If you want the GUI before login, configure auto-login or use a display-manager-level autostart."
BASH
        chmod +x "$BIN_DIR/xui_enable_autostart.sh" || true
}

# -------------------------
# Additional utilities
# -------------------------
write_asset_generator(){
    info "Writing asset generator and PyQt prototype"
    mkdir -p "$BIN_DIR"
    cat > "$BIN_DIR/xui_gen_assets.py" <<'PY'
#!/usr/bin/env python3
import os
from PIL import Image, ImageDraw, ImageFont
XUI=os.path.expanduser('~/.xui')
ASSETS=os.path.join(XUI,'assets')
os.makedirs(ASSETS, exist_ok=True)
names = ['Casino','Runner','Store','Misiones','Perfil','Compat X86','LAN','Power Profile','Battery Saver']
for n in names:
    fn = os.path.join(ASSETS, f"{n}.png")
    if os.path.exists(fn):
        continue
    img = Image.new('RGB', (320,180), color=(12,84,166))
    d = ImageDraw.Draw(img)
    try:
        f = ImageFont.load_default()
    except Exception:
        f = None
    txt = n
    w,h = d.textsize(txt, font=f)
    d.text(((320-w)/2,(180-h)/2), txt, font=f, fill=(255,255,255))
    img.save(fn)
print('assets_generated')
PY
    chmod +x "$BIN_DIR/xui_gen_assets.py"

    cat > "$DASH_DIR/pyqt_dashboard.py" <<'PY'
#!/usr/bin/env python3
import sys, os
from pathlib import Path
ASSETS = Path.home()/'.xui'/'assets'
try:
    from PyQt5 import QtWidgets, QtGui, QtCore
except Exception:
    print('PyQt5 not installed')
    sys.exit(1)


class TileWidget(QtWidgets.QFrame):
    def __init__(self, name, img_path=None, parent=None, big=False):
        super().__init__(parent)
        self.name = name
        # Prefer explicit img_path; if missing, fall back to applogo.png in assets
        if img_path:
            self.img_path = img_path
        else:
            fallback = ASSETS / 'applogo.png'
            self.img_path = fallback if fallback.exists() else None
        self.big = big
        self.setObjectName('tile')
        self.setFocusPolicy(QtCore.Qt.StrongFocus)
        self.setStyleSheet(self.default_style())
        v = QtWidgets.QVBoxLayout(self)
        self.img_label = QtWidgets.QLabel()
        self.img_label.setAlignment(QtCore.Qt.AlignCenter)
        if img_path and img_path.exists():
            pix = QtGui.QPixmap(str(img_path)).scaled(400 if big else 220, 220 if big else 120, QtCore.Qt.KeepAspectRatio, QtCore.Qt.SmoothTransformation)
            self.img_label.setPixmap(pix)
        else:
            self.img_label.setText('')
            self.img_label.setFixedHeight(180 if big else 100)
        self.title = QtWidgets.QLabel(name)
        self.title.setAlignment(QtCore.Qt.AlignCenter)
        self.title.setStyleSheet('color:white;')
        v.addWidget(self.img_label)
        v.addWidget(self.title)
        self.anim = QtCore.QPropertyAnimation(self, b"geometry")

    def default_style(self):
        return "QFrame#tile { background: #0C54A6; border: 2px solid #08375a; border-radius:8px; } QLabel { color: white; }"

    def focusInEvent(self, e):
        # zoom animation
        rect = self.geometry()
        self.anim.stop()
        self.anim.setDuration(160)
        self.anim.setStartValue(rect)
        self.anim.setEndValue(QtCore.QRect(rect.x()-6, rect.y()-6, rect.width()+12, rect.height()+12))
        self.anim.start()
        self.setStyleSheet("QFrame#tile { background: #1E90FF; border: 3px solid #00FFFF; border-radius:8px; } QLabel { color: white; font-weight: bold; }")
        super().focusInEvent(e)

    def focusOutEvent(self, e):
        self.anim.stop()
        rect = self.geometry()
        self.anim.setDuration(120)
        self.anim.setStartValue(rect)
        self.anim.setEndValue(QtCore.QRect(rect.x()+6, rect.y()+6, rect.width()-12, rect.height()-12))
        self.anim.start()
        self.setStyleSheet(self.default_style())
        super().focusOutEvent(e)

    def mousePressEvent(self, e):
        self.clicked()

    def clicked(self):
        # map name to action
        xui = os.path.expanduser('~/.xui')
        mapping = {
            'Casino': ['python3', os.path.join(xui,'casino','casino.py')],
            'Runner': ['python3', os.path.join(xui,'games','runner.py')],
            'Store': ['bash', os.path.join(xui,'bin','xui_store.sh')],
            'LAN': ['python3', os.path.join(xui,'bin','xui_social_chat.py')],
            'Power Profile': ['bash', os.path.join(xui,'bin','xui_battery_profile.sh'), 'balanced'],
            'Battery Saver': ['bash', os.path.join(xui,'bin','xui_battery_saver.sh'), 'toggle'],
        }
        cmd = mapping.get(self.name)
        if cmd:
            try:
                QtCore.QProcess.startDetached(cmd[0], cmd[1:])
            except Exception:
                pass


class MainWindow(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle('XUI GUI - Xbox Style')
        central = QtWidgets.QWidget()
        main_l = QtWidgets.QHBoxLayout(central)
        # left panel
        left = QtWidgets.QVBoxLayout()
        user_lbl = QtWidgets.QLabel('Usuario')
        user_lbl.setStyleSheet('color:white; font-weight:bold;')
        left.addWidget(user_lbl)
        left.addSpacing(10)
        # quick tiles on left column
        left_tiles = ['Perfil','Compat X86']
        for t in left_tiles:
            lbl = QtWidgets.QLabel(t)
            lbl.setStyleSheet('background:#0C54A6; color:white; padding:8px; border-radius:6px;')
            lbl.setFixedHeight(48)
            left.addWidget(lbl)
            left.addSpacing(6)
        left.addStretch()
        left_widget = QtWidgets.QFrame()
        left_widget.setLayout(left)
        left_widget.setFixedWidth(180)
        left_widget.setStyleSheet('background: #000;')

        # center: hero + tiles
        center = QtWidgets.QWidget()
        grid = QtWidgets.QGridLayout(center)
        # hero tile spans two rows and two columns
        names = ['Casino','Runner','Store','Misiones','LAN','Power Profile','Battery Saver']
        hero = TileWidget('Casino', ASSETS/'Casino.png', big=True)
        grid.addWidget(hero, 0, 0, 2, 2)
        others = ['Runner','Store','Misiones','LAN','Power Profile','Battery Saver']
        positions = [(0,2),(1,2),(2,0),(2,1),(2,2),(3,0)]
        idx = 0
        self.tiles = [hero]
        for name,pos in zip(others, positions):
            img_webp = ASSETS/(f"{name}.webp")
            img_png = ASSETS/(f"{name}.png")
            img = img_webp if img_webp.exists() else (img_png if img_png.exists() else None)
            tw = TileWidget(name, img if img is not None else None, big=False)
            grid.addWidget(tw, pos[0], pos[1])
            self.tiles.append(tw)

        # right column: featured list
        right = QtWidgets.QVBoxLayout()
        right_title = QtWidgets.QLabel('Featured')
        right_title.setStyleSheet('color:white; font-weight:bold')
        right.addWidget(right_title)
        for i in range(4):
            lbl = QtWidgets.QLabel(f'Featured {i+1}')
            lbl.setFixedHeight(70)
            lbl.setStyleSheet('background:#111; color:white; border:1px solid #333; padding:6px;')
            right.addWidget(lbl)
            right.addSpacing(8)
        right.addStretch()
        right_widget = QtWidgets.QFrame()
        right_widget.setLayout(right)
        right_widget.setFixedWidth(240)

        main_l.addWidget(left_widget)
        main_l.addWidget(center, 1)
        main_l.addWidget(right_widget)

        self.setCentralWidget(central)
        self.current_index = 0
        QtCore.QTimer.singleShot(120, self.update_focus)

    def update_focus(self):
        if 0 <= self.current_index < len(self.tiles):
            self.tiles[self.current_index].setFocus()

    def keyPressEvent(self, e):
        key = e.key()
        cols = 3
        r = self.current_index // cols
        c = self.current_index % cols
        if key == QtCore.Qt.Key_Left:
            c = max(0, c-1)
        elif key == QtCore.Qt.Key_Right:
            c = min(cols-1, c+1)
        elif key == QtCore.Qt.Key_Up:
            r = max(0, r-1)
        elif key == QtCore.Qt.Key_Down:
            r = min(3, r+1)
        elif key == QtCore.Qt.Key_Return or key == QtCore.Qt.Key_Enter:
            self.tiles[self.current_index].clicked()
            return
        else:
            super().keyPressEvent(e)
            return
        new_index = r*cols + c
        new_index = max(0, min(new_index, len(self.tiles)-1))
        self.current_index = new_index
        self.update_focus()

if __name__=='__main__':
    app = QtWidgets.QApplication(sys.argv)
    w = MainWindow()
    w.resize(1200,720)
    w.show()
    sys.exit(app.exec_())
PY
    chmod +x "$DASH_DIR/pyqt_dashboard.py"
}

post_create_assets(){
    # ensure generator exists
    write_asset_generator
    # run python generator; install Pillow if allowed and missing
    if python3 - <<'PY' >/dev/null 2>&1
try:
    from PIL import Image
    print('ok')
except Exception:
    raise SystemExit(2)
PY
    then
        python3 "$BIN_DIR/xui_gen_assets.py" || true
    else
        if [ "$XUI_INSTALL_SYSTEM" = "1" ]; then
            info "Pillow missing, attempting to install"
            pip_install Pillow || warn "Could not install Pillow; assets may not be generated"
            python3 "$BIN_DIR/xui_gen_assets.py" || true
        else
            warn "Pillow not available; run installer with --yes-install to auto-install and generate assets"
        fi
    fi
}
write_logger_and_helpers(){
    info "Writing logger helper and log rotate script"
    cat > "$BIN_DIR/xui_log.sh" <<'BASH'
#!/usr/bin/env bash
LOG="$HOME/.xui/logs/xui.log"
mkdir -p "$(dirname "$LOG")"
msg="$*"
ts=$(date --iso-8601=seconds)
echo "$ts $msg" >> "$LOG"
BASH
    chmod +x "$BIN_DIR/xui_log.sh"

    # simple logrotate helper
    cat > "$BIN_DIR/xui_log_rotate.sh" <<'BASH'
#!/usr/bin/env bash
LOGDIR="$HOME/.xui/logs"
mkdir -p "$LOGDIR"
find "$LOGDIR" -name '*.log' -type f -size +100k -exec gzip -9 {} \; || true
BASH
    chmod +x "$BIN_DIR/xui_log_rotate.sh"
}

write_backup_restore(){
    info "Writing backup and restore scripts"
    cat > "$BIN_DIR/xui_backup.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
DST="$HOME/.xui/backups/xui-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
mkdir -p "$HOME/.xui/backups"
tar -czf "$DST" -C "$HOME/.xui" data bin dashboard casino games assets || true
echo "$DST"
BASH
    chmod +x "$BIN_DIR/xui_backup.sh"

    cat > "$BIN_DIR/xui_restore.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
ARCH=${1:-}
if [ -z "$ARCH" ]; then echo "Usage: $0 <backup-archive>"; exit 1; fi
tar -xzf "$ARCH" -C "$HOME/.xui" || { echo "Restore failed"; exit 1; }
echo "Restored from $ARCH"
BASH
    chmod +x "$BIN_DIR/xui_restore.sh"
}

write_diagnostics(){
    info "Writing diagnostics script"
    cat > "$BIN_DIR/xui_diag.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
echo "XUI Diagnostics"
echo "Date: $(date)"
echo "User: $USER"
echo "OS: $(lsb_release -ds 2>/dev/null || uname -a)"
echo "Disk usage:"; df -h /
echo "Memory:"; free -h
echo "Processes (top 5):"; ps aux --sort=-%mem | head -n 6
echo "Installed: box64=$(command -v box64 >/dev/null 2>&1 && echo yes || echo no) fex=$(command -v fex >/dev/null 2>&1 && echo yes || echo no)"
echo "Python libs:"; python3 -c "import pkgutil;print([m.name for m in pkgutil.iter_modules() if m.name in ('urwid','evdev')])" 2>/dev/null || true
BASH
    chmod +x "$BIN_DIR/xui_diag.sh"
}

write_profiles_manager(){
    info "Writing simple profiles manager"
    mkdir -p "$DATA_DIR/profiles"
    cat > "$BIN_DIR/xui_profile.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
PROFDIR="$HOME/.xui/data/profiles"
mkdir -p "$PROFDIR"
case ${1:-list} in
    list) ls -1 "$PROFDIR" || echo "no profiles"; ;;
    save)
        name=${2:-default}
        tar -czf "$PROFDIR/$name.tgz" -C "$HOME/.xui" data || echo saved
        ;;
    restore)
        file=$2
        tar -xzf "$file" -C "$HOME/.xui" || echo restored
        ;;
    *) echo "Usage: $0 {list|save <name>|restore <file>}"; exit 1;;
esac
BASH
    chmod +x "$BIN_DIR/xui_profile.sh"
}

write_plugins_skeleton(){
    info "Writing plugin skeleton and loader"
    mkdir -p "$XUI_DIR/plugins"
    cat > "$XUI_DIR/plugins/README.md" <<TXT
XUI plugins: drop executable Python scripts here. The Dashboard may load plugins by launching them.
TXT
    cat > "$BIN_DIR/xui_plugin_mgr.sh" <<'BASH'
#!/usr/bin/env bash
PLUGDIR="$HOME/.xui/plugins"
case ${1:-list} in
    list) ls -1 "$PLUGDIR" || echo none;;
    run)
        for f in "$PLUGDIR"/*; do [ -x "$f" ] && "$f" || true; done
        ;;
    *) echo "Usage: $0 {list|run}"; exit 1;;
esac
BASH
    chmod +x "$BIN_DIR/xui_plugin_mgr.sh"
}

write_auto_update(){
    info "Writing auto-update checker"
    cat > "$BIN_DIR/xui_update_check.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
MODE=${1:-status}
SRC=${XUI_SOURCE_DIR:-$HOME/Descargas/xui}
case "$MODE" in
  status)
    if [ -d "$SRC/.git" ]; then
      git -C "$SRC" fetch --all --prune >/dev/null 2>&1 || true
      git -C "$SRC" status -sb
    else
      echo "No git repo at $SRC"
      echo "Tip: export XUI_SOURCE_DIR=/path/to/repo"
    fi
    ;;
  pull)
    if [ -d "$SRC/.git" ]; then
      git -C "$SRC" pull --ff-only
    else
      echo "No git repo at $SRC"
      exit 1
    fi
    ;;
  release)
    REPO=${XUI_UPDATE_REPO:-}
    if [ -z "$REPO" ]; then
      echo "Set XUI_UPDATE_REPO=user/repo to query latest release"
      exit 1
    fi
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | python3 - <<'PY'
import json,sys
try:
  d=json.load(sys.stdin)
  print("Latest release:", d.get("tag_name","unknown"))
except Exception:
  print("Could not parse release data")
PY
    else
      echo "curl required"
      exit 1
    fi
    ;;
  *)
    echo "Usage: $0 {status|pull|release}"
    exit 1
    ;;
esac
if [ "$MODE" = "status" ]; then
  echo "OK"
fi
BASH
    chmod +x "$BIN_DIR/xui_update_check.sh"
}

write_uninstall(){
    info "Writing uninstall script"
    cat > "$BIN_DIR/xui_uninstall.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
read -p "This will remove ~/.xui (files only). Continue? [s/N] " r
case "$r" in [sS]) rm -rf "$HOME/.xui"; echo removed;; *) echo aborted; exit 1;; esac
BASH
    chmod +x "$BIN_DIR/xui_uninstall.sh"
}

write_readme_and_requirements(){
    info "Writing README and requirements"
    cat > "$XUI_DIR/README.md" <<TXT
XUI 4.0XV - Ultra Master Installer
Files installed under ~/.xui
Use systemctl --user to enable services
TXT
    cat > "$XUI_DIR/requirements.txt" <<REQ
urwid
evdev
REQ
}

write_basic_tests(){
    info "Writing basic tests"
    mkdir -p "$XUI_DIR/tests"
    cat > "$XUI_DIR/tests/test_balance.py" <<PY
import json, os
f=os.path.expanduser('~/.xui/data/saldo.json')
def test_balance_exists():
        assert os.path.exists(f)
        d=json.load(open(f))
        assert 'balance' in d
PY
}

write_apps_utilities(){
    info "Writing utilities and lightweight apps"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Prefer user-provided sounds from SONIDOS (or user_sounds) and install them into assets.
    if [ -d "$script_dir/SONIDOS" ] || [ -d "$script_dir/sonidos" ] || [ -d "$script_dir/user_sounds" ]; then
        mkdir -p "$ASSETS_DIR/SONIDOS"
        for d in "$script_dir/SONIDOS" "$script_dir/sonidos" "$script_dir/user_sounds"; do
            [ -d "$d" ] || continue
            find "$d" -type f \( -iname '*.mp3' -o -iname '*.wav' \) -print0 | while IFS= read -r -d '' f; do
                bn="$(basename "$f")"
                cp -f "$f" "$ASSETS_DIR/SONIDOS/$bn" || true
                case "${bn,,}" in
                    startup.mp3) cp -f "$f" "$ASSETS_DIR/startup.mp3" || true ;;
                esac
                info "Installed sound: SONIDOS/$bn"
            done
        done
    fi

    # Screenshot utility
    cat > "$BIN_DIR/xui_screenshot.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
OUT="$HOME/.xui/assets/screenshot-$(date +%Y%m%d-%H%M%S).png"
mkdir -p "$(dirname "$OUT")"
if command -v maim >/dev/null 2>&1; then
    maim "$OUT"
elif command -v scrot >/dev/null 2>&1; then
    scrot "$OUT"
else
    echo "No screenshot tool installed"
    exit 1
fi
echo "$OUT"
BASH
    chmod +x "$BIN_DIR/xui_screenshot.sh"

    # System monitor (top-like summary)
    cat > "$BIN_DIR/xui_sysmon.sh" <<'BASH'
#!/usr/bin/env bash
htop || top -b -n1 | head -n 20
BASH
    chmod +x "$BIN_DIR/xui_sysmon.sh"

    # Quick browser launcher
cat > "$BIN_DIR/xui_browser.sh" <<'BASH'
#!/usr/bin/env bash
# xui_browser.sh - launcher with kiosk support and fallback to text browser
MODE=normal
URL=${1:-}
if [ "$1" = "--kiosk" ]; then MODE=kiosk; shift; URL=${1:-}
fi
if [ -z "$URL" ]; then URL="about:blank"; fi

# Preferred kiosk path: Qt WebEngine wrapper with ESC close.
if [ "$MODE" = "kiosk" ] && command -v python3 >/dev/null 2>&1; then
    if python3 - <<'PY' >/dev/null 2>&1
from PyQt5 import QtWebEngineWidgets
PY
    then
        python3 - "$URL" <<'PY'
import sys
from PyQt5 import QtWidgets, QtCore, QtGui, QtWebEngineWidgets
url = sys.argv[1] if len(sys.argv) > 1 else 'about:blank'
app = QtWidgets.QApplication([])
w = QtWidgets.QMainWindow()
w.setWindowTitle(url)
view = QtWebEngineWidgets.QWebEngineView()
view.load(QtCore.QUrl(url))
w.setCentralWidget(view)
QtWidgets.QShortcut(QtGui.QKeySequence(QtCore.Qt.Key_Escape), w, activated=w.close)
QtWidgets.QShortcut(QtGui.QKeySequence(QtCore.Qt.Key_Back), w, activated=w.close)
w.showFullScreen()
sys.exit(app.exec_())
PY
        exit $?
    fi
fi

if command -v firefox >/dev/null 2>&1; then
    if [ "$MODE" = "kiosk" ]; then
        firefox --kiosk "$URL" &
    else
        firefox "$URL" &
    fi
elif command -v chromium-browser >/dev/null 2>&1; then
    if [ "$MODE" = "kiosk" ]; then
        chromium-browser --kiosk "$URL" &
    else
        chromium-browser "$URL" &
    fi
elif command -v chromium >/dev/null 2>&1; then
    if [ "$MODE" = "kiosk" ]; then
        chromium --kiosk "$URL" &
    else
        chromium "$URL" &
    fi
elif command -v x-www-browser >/dev/null 2>&1; then
    x-www-browser "$URL" &
elif command -v w3m >/dev/null 2>&1; then
    # text-mode browser fallback
    exec w3m "$URL"
else
    echo "No browser found. Install Firefox/Chromium or w3m." >&2
    exit 1
fi
BASH
    chmod +x "$BIN_DIR/xui_browser.sh"

    # Quick notes
    cat > "$BIN_DIR/xui_note.sh" <<'BASH'
#!/usr/bin/env bash
NOTES="$HOME/.xui/data/notes.txt"
mkdir -p "$(dirname "$NOTES")"
${EDITOR:-nano} "$NOTES"
BASH
    chmod +x "$BIN_DIR/xui_note.sh"

    # Social LAN/P2P chat (Xbox-like messaging between dashboards)
    cat > "$BIN_DIR/xui_social_chat.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import queue
import socket
import subprocess
import threading
import time
import urllib.request
import uuid
from pathlib import Path
from PyQt5 import QtCore, QtWidgets

XUI_HOME = Path.home() / '.xui'
DATA_HOME = XUI_HOME / 'data'
PROFILE_FILE = DATA_HOME / 'profile.json'
PEERS_FILE = DATA_HOME / 'social_peers.json'

DISCOVERY_PORT = int(os.environ.get('XUI_CHAT_DISCOVERY_PORT', '38655'))
CHAT_PORT_BASE = int(os.environ.get('XUI_CHAT_PORT', '38600'))
ANNOUNCE_INTERVAL = 2.5


def safe_json_read(path, default):
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except Exception:
        return default


def safe_json_write(path, data):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=2), encoding='utf-8')


def load_gamertag():
    p = safe_json_read(PROFILE_FILE, {})
    name = str(p.get('gamertag', 'Player1')).strip()
    return name or 'Player1'


def list_local_ips():
    ips = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip and not ip.startswith('127.'):
                ips.add(ip)
    except Exception:
        pass
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('1.1.1.1', 80))
        ip = s.getsockname()[0]
        s.close()
        if ip and not ip.startswith('127.'):
            ips.add(ip)
    except Exception:
        pass
    try:
        for ip in subprocess.getoutput('hostname -I 2>/dev/null').split():
            if ip and not ip.startswith('127.'):
                ips.add(ip)
    except Exception:
        pass
    return sorted(ips) if ips else ['127.0.0.1']


def list_local_broadcasts():
    targets = set()
    try:
        out = subprocess.getoutput('ip -o -4 addr show scope global 2>/dev/null')
        for line in out.splitlines():
            parts = line.split()
            if 'brd' in parts:
                idx = parts.index('brd')
                if idx + 1 < len(parts):
                    brd = parts[idx + 1].strip()
                    if brd and not brd.startswith('127.'):
                        targets.add(brd)
    except Exception:
        pass
    return sorted(targets)


def get_public_ip():
    try:
        with urllib.request.urlopen('https://api.ipify.org', timeout=2) as r:
            ip = r.read().decode('utf-8', errors='ignore').strip()
            if ip:
                return ip
    except Exception:
        pass
    return ''


def choose_port(base, span=24):
    for port in range(base, base + span):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(('', port))
            s.close()
            return port
        except OSError:
            s.close()
            continue
    return 0


def parse_peer_input(raw):
    txt = str(raw or '').strip()
    if not txt:
        return None
    alias = ''
    if '@' in txt:
        alias, txt = txt.split('@', 1)
    txt = txt.strip()
    if ':' not in txt:
        return None
    host, port_s = txt.rsplit(':', 1)
    host = host.strip()
    try:
        port = int(port_s.strip())
    except Exception:
        return None
    if not host or port < 1 or port > 65535:
        return None
    return {
        'name': alias.strip() or host,
        'host': host,
        'port': port,
        'source': 'manual',
    }


class SocialNetworkEngine:
    def __init__(self, nickname):
        self.nickname = nickname
        self.node_id = uuid.uuid4().hex[:12]
        self.chat_port = choose_port(CHAT_PORT_BASE)
        self.events = queue.Queue()
        self.running = False
        self.threads = []
        self.peers = {}
        self.lock = threading.Lock()
        self.local_ips = set(list_local_ips())

    def start(self):
        self.running = True
        for target in (self._tcp_server_loop, self._discovery_listener_loop, self._discovery_sender_loop, self._peer_gc_loop):
            t = threading.Thread(target=target, daemon=True)
            self.threads.append(t)
            t.start()
        if self.chat_port:
            self.events.put(('status', f'Chat TCP listening on port {self.chat_port}'))
        else:
            self.events.put(('status', 'No free TCP chat port found.'))

    def stop(self):
        self.running = False
        for t in self.threads:
            t.join(timeout=0.2)

    def send_chat(self, host, port, text):
        payload = {
            'type': 'chat',
            'node_id': self.node_id,
            'from': self.nickname,
            'text': text,
            'ts': time.time(),
            'reply_port': self.chat_port,
        }
        body = (json.dumps(payload, ensure_ascii=False) + '\n').encode('utf-8', errors='ignore')
        with socket.create_connection((host, int(port)), timeout=4) as s:
            s.sendall(body)

    def _is_local_host(self, host):
        h = str(host or '').strip()
        if not h:
            return False
        return h.startswith('127.') or h in self.local_ips

    def _push_peer(self, name, host, port, source='LAN', node_id=''):
        if not host or not port:
            return
        key = f'{host}:{int(port)}'
        now = time.time()
        with self.lock:
            prev = self.peers.get(key)
            self.peers[key] = {
                'name': name or host,
                'host': host,
                'port': int(port),
                'source': source,
                'node_id': str(node_id or ''),
                'last_seen': now,
            }
        if prev is None or prev.get('name') != name or prev.get('node_id') != str(node_id or ''):
            self.events.put(('peer_up', key, name or host, host, int(port), source, str(node_id or '')))

    def _peer_gc_loop(self):
        while self.running:
            time.sleep(2.0)
            now = time.time()
            stale = []
            with self.lock:
                for key, peer in self.peers.items():
                    if peer.get('source') == 'LAN' and (now - peer.get('last_seen', 0.0)) > 10.0:
                        stale.append(key)
                for key in stale:
                    self.peers.pop(key, None)
            for key in stale:
                self.events.put(('peer_down', key))

    def _discovery_targets(self):
        targets = [('255.255.255.255', DISCOVERY_PORT)]
        seen = {targets[0]}
        for brd in list_local_broadcasts():
            target = (str(brd), DISCOVERY_PORT)
            if target not in seen:
                seen.add(target)
                targets.append(target)
        return targets

    def _announce_packet(self):
        return {
            'type': 'announce',
            'node_id': self.node_id,
            'name': self.nickname,
            'chat_port': self.chat_port,
            'reply_port': DISCOVERY_PORT,
            'ts': time.time(),
        }

    def _probe_packet(self):
        return {
            'type': 'probe',
            'node_id': self.node_id,
            'name': self.nickname,
            'chat_port': self.chat_port,
            'reply_port': DISCOVERY_PORT,
            'ts': time.time(),
        }

    def _discovery_sender_loop(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        targets = self._discovery_targets()
        ticks = 0
        self.events.put(('status', f'LAN autodiscovery active on UDP {DISCOVERY_PORT}'))
        while self.running:
            if ticks % 8 == 0:
                targets = self._discovery_targets()
            packets = [self._announce_packet()]
            if ticks % 2 == 0:
                packets.insert(0, self._probe_packet())
            for packet in packets:
                raw = json.dumps(packet).encode('utf-8', errors='ignore')
                for target in targets:
                    try:
                        sock.sendto(raw, target)
                    except Exception:
                        pass
            time.sleep(ANNOUNCE_INTERVAL)
            ticks += 1
        sock.close()

    def _discovery_listener_loop(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(('', DISCOVERY_PORT))
        except OSError:
            self.events.put(('status', f'Cannot bind UDP discovery port {DISCOVERY_PORT}.'))
            sock.close()
            return
        sock.settimeout(1.0)
        while self.running:
            try:
                raw, addr = sock.recvfrom(4096)
            except socket.timeout:
                continue
            except Exception:
                continue
            host = addr[0]
            if self._is_local_host(host):
                continue
            try:
                data = json.loads(raw.decode('utf-8', errors='ignore'))
            except Exception:
                continue
            remote_node = str(data.get('node_id') or '')
            if remote_node == self.node_id:
                continue
            ptype = str(data.get('type') or '')
            try:
                port = int(data.get('chat_port') or 0)
            except Exception:
                port = 0
            name = str(data.get('name') or host)
            if ptype == 'probe':
                reply = self._announce_packet()
                try:
                    sock.sendto(json.dumps(reply).encode('utf-8', errors='ignore'), (host, DISCOVERY_PORT))
                except Exception:
                    pass
                if port > 0:
                    self._push_peer(name, host, port, 'LAN', remote_node)
                continue
            if ptype != 'announce':
                continue
            if port <= 0:
                continue
            self._push_peer(name, host, port, 'LAN', remote_node)
        sock.close()

    def _tcp_server_loop(self):
        if not self.chat_port:
            return
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            srv.bind(('', self.chat_port))
            srv.listen(24)
        except OSError:
            self.events.put(('status', f'Cannot open TCP chat server on {self.chat_port}.'))
            self.chat_port = 0
            srv.close()
            return
        srv.settimeout(1.0)
        while self.running:
            try:
                conn, addr = srv.accept()
            except socket.timeout:
                continue
            except Exception:
                continue
            host = addr[0]
            with conn:
                try:
                    payload = conn.recv(65536).decode('utf-8', errors='ignore')
                except Exception:
                    payload = ''
            if not payload.strip():
                continue
            for line in payload.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except Exception:
                    continue
                if msg.get('type') != 'chat':
                    continue
                name = str(msg.get('from') or host)
                text = str(msg.get('text') or '').strip()
                sender_node = str(msg.get('node_id') or '')
                try:
                    reply_port = int(msg.get('reply_port') or 0)
                except Exception:
                    reply_port = 0
                if reply_port > 0:
                    self._push_peer(name, host, reply_port, 'LAN', sender_node)
                if text:
                    self.events.put(('chat', name, host, reply_port, text, float(msg.get('ts') or time.time())))
        srv.close()


class SocialChatWindow(QtWidgets.QWidget):
    def __init__(self):
        super().__init__()
        DATA_HOME.mkdir(parents=True, exist_ok=True)
        self.nickname = load_gamertag()
        self.setWindowTitle(f'XUI Social Chat - {self.nickname}')
        self.resize(1180, 720)
        self.engine = SocialNetworkEngine(self.nickname)
        self.peer_items = {}
        self.peer_data = {}
        self._build_ui()
        self._load_manual_peers()
        self.engine.start()
        self.timer = QtCore.QTimer(self)
        self.timer.timeout.connect(self._poll_events)
        self.timer.start(120)
        self._append_system('LAN autodiscovery enabled (broadcast + probe). Add manual peer for Internet P2P.')

    def _build_ui(self):
        self.setStyleSheet('''
            QWidget { background:#1a1f25; color:#e9eff2; font-size:15px; }
            QListWidget { background:#12171d; border:1px solid #2d3641; }
            QPlainTextEdit { background:#0f141a; border:1px solid #2d3641; }
            QLineEdit { background:#10161d; border:1px solid #2d3641; padding:6px; }
            QPushButton { background:#2aaa49; border:1px solid #5ce27f; color:#eefaf0; padding:8px 12px; font-weight:700; }
            QPushButton:hover { background:#33bf54; }
        ''')
        root = QtWidgets.QHBoxLayout(self)
        root.setContentsMargins(12, 12, 12, 12)
        root.setSpacing(10)

        left = QtWidgets.QVBoxLayout()
        left_title = QtWidgets.QLabel('Peers (LAN / P2P)')
        left_title.setStyleSheet('font-size:22px; font-weight:700;')
        self.peer_list = QtWidgets.QListWidget()
        self.peer_list.setMinimumWidth(360)
        self.btn_add = QtWidgets.QPushButton('Add Peer ID')
        self.btn_me = QtWidgets.QPushButton('My Peer IDs')
        self.btn_lan = QtWidgets.QPushButton('LAN Status')
        self.btn_add.clicked.connect(self._add_peer_dialog)
        self.btn_me.clicked.connect(self._show_my_peer_ids)
        self.btn_lan.clicked.connect(self._show_lan_status)

        left.addWidget(left_title)
        left.addWidget(self.peer_list, 1)
        left.addWidget(self.btn_add)
        left.addWidget(self.btn_me)
        left.addWidget(self.btn_lan)

        right = QtWidgets.QVBoxLayout()
        self.chat = QtWidgets.QPlainTextEdit()
        self.chat.setReadOnly(True)
        self.chat.setLineWrapMode(QtWidgets.QPlainTextEdit.WidgetWidth)
        self.msg = QtWidgets.QLineEdit()
        self.msg.setPlaceholderText('Write a message...')
        self.btn_send = QtWidgets.QPushButton('Send')
        self.btn_send.clicked.connect(self._send_current)
        self.msg.returnPressed.connect(self._send_current)
        self.status = QtWidgets.QLabel('Ready')
        self.status.setStyleSheet('color:#99a9b7;')

        bottom = QtWidgets.QHBoxLayout()
        bottom.addWidget(self.msg, 1)
        bottom.addWidget(self.btn_send)

        right.addWidget(self.chat, 1)
        right.addLayout(bottom)
        right.addWidget(self.status)

        root.addLayout(left)
        root.addLayout(right, 1)

    def _peer_row_text(self, p):
        return f"{p['name']}  [{p['host']}:{p['port']}]  ({p['source']})"

    def _upsert_peer(self, name, host, port, source='LAN', node_id='', persist=False):
        key = f'{host}:{int(port)}'
        data = {
            'name': (name or host).strip() or host,
            'host': host,
            'port': int(port),
            'source': source,
            'node_id': str(node_id or ''),
        }
        if key in self.peer_items:
            self.peer_data[key].update(data)
            self.peer_items[key].setText(self._peer_row_text(self.peer_data[key]))
        else:
            item = QtWidgets.QListWidgetItem(self._peer_row_text(data))
            item.setData(QtCore.Qt.UserRole, key)
            self.peer_list.addItem(item)
            self.peer_items[key] = item
            self.peer_data[key] = data
            if self.peer_list.currentRow() < 0:
                self.peer_list.setCurrentRow(0)
        if persist:
            self._save_manual_peers()

    def _remove_peer(self, key):
        item = self.peer_items.pop(key, None)
        self.peer_data.pop(key, None)
        if item is None:
            return
        row = self.peer_list.row(item)
        if row >= 0:
            self.peer_list.takeItem(row)

    def _append_line(self, line):
        self.chat.appendPlainText(line)
        sb = self.chat.verticalScrollBar()
        sb.setValue(sb.maximum())

    def _append_system(self, text):
        hhmm = time.strftime('%H:%M:%S')
        self._append_line(f'[{hhmm}] [SYSTEM] {text}')

    def _append_msg(self, sender, text):
        hhmm = time.strftime('%H:%M:%S')
        self._append_line(f'[{hhmm}] {sender}: {text}')

    def _current_peer(self):
        item = self.peer_list.currentItem()
        if not item:
            return None
        key = item.data(QtCore.Qt.UserRole)
        return self.peer_data.get(key)

    def _host_priority(self, host):
        h = str(host or '')
        if h.startswith('127.'):
            return 30
        if h.startswith('10.0.2.'):
            return 20
        return 0

    def _send_candidates(self, peer):
        selected_host = str(peer.get('host') or '')
        selected_port = int(peer.get('port') or 0)
        selected_name = str(peer.get('name') or '').strip().lower()
        selected_node = str(peer.get('node_id') or '')
        weighted = []
        for key, p in self.peer_data.items():
            host = str(p.get('host') or '')
            try:
                port = int(p.get('port') or 0)
            except Exception:
                port = 0
            if not host or port <= 0:
                continue
            src = str(p.get('source') or '')
            name = str(p.get('name') or '').strip().lower()
            node = str(p.get('node_id') or '')
            rank = 9
            if host == selected_host and port == selected_port:
                rank = 0
            elif selected_node and node and node == selected_node:
                rank = 1
            elif host == selected_host:
                rank = 2
            elif src == 'LAN' and selected_name and name == selected_name:
                rank = 3
            weighted.append((rank, self._host_priority(host), host, port, key))
        weighted.sort(key=lambda x: (x[0], x[1], x[2], x[3]))
        out = []
        seen = set()
        for _rank, _hp, host, port, key in weighted:
            endpoint = (host, int(port))
            if endpoint in seen:
                continue
            seen.add(endpoint)
            out.append((host, int(port), key))
        return out

    def _send_current(self):
        peer = self._current_peer()
        if not peer:
            QtWidgets.QMessageBox.information(self, 'Peer required', 'Select a LAN/P2P peer first.')
            return
        text = self.msg.text().strip()
        if not text:
            return
        last_err = None
        used = None
        candidates = self._send_candidates(peer)
        for host, port, key in candidates:
            try:
                self.engine.send_chat(host, port, text)
                used = (host, int(port), key)
                break
            except Exception as e:
                last_err = e
                continue
        if used:
            host, port, key = used
            self._append_msg(f'You -> {peer["name"]}', text)
            if host == str(peer.get('host')) and int(port) == int(peer.get('port') or 0):
                self.status.setText(f'Sent to {host}:{port}')
            else:
                self.status.setText(f'Sent via fallback {host}:{port}')
                item = self.peer_items.get(key)
                if item is not None:
                    self.peer_list.setCurrentItem(item)
            self.msg.clear()
            return
        err = str(last_err) if last_err is not None else 'No reachable peer endpoint.'
        self.status.setText(f'Cannot send: {err}')
        QtWidgets.QMessageBox.warning(
            self,
            'Send failed',
            f'Could not connect to selected peer candidates.\n\n'
            'If peer is on Internet, use Tailscale/ZeroTier or forward TCP 38600.\n'
            f'Error: {err}'
        )

    def _add_peer_dialog(self):
        txt, ok = QtWidgets.QInputDialog.getText(
            self,
            'Add P2P peer',
            'Format: alias@host:port or host:port',
            text=''
        )
        if not ok:
            return
        parsed = parse_peer_input(txt)
        if not parsed:
            QtWidgets.QMessageBox.warning(self, 'Invalid format', 'Use alias@host:port or host:port')
            return
        self._upsert_peer(parsed['name'], parsed['host'], parsed['port'], 'manual', persist=True)
        self._append_system(f'Manual peer added: {parsed["host"]}:{parsed["port"]}')

    def _show_my_peer_ids(self):
        ips = list_local_ips()
        ids = [f'{ip}:{self.engine.chat_port}' for ip in ips]
        pub = get_public_ip()
        lines = ['LAN IDs:'] + [f'  {v}' for v in ids]
        if not self.engine.chat_port:
            lines += ['', 'Warning: chat TCP server is not active on this dashboard.']
        if ips and all(str(ip).startswith('10.0.2.') for ip in ips):
            lines += ['', 'VirtualBox NAT detected (10.0.2.x only).', 'Use Bridged or Host-Only Adapter for VM-to-VM LAN chat.']
        if pub:
            lines += ['', f'Public IP (approx): {pub}:{self.engine.chat_port}']
        lines += ['', 'Tip: for Internet P2P use Tailscale/ZeroTier or router port-forward TCP 38600.']
        QtWidgets.QMessageBox.information(self, 'My Peer IDs', '\n'.join(lines))

    def _show_lan_status(self):
        out = subprocess.getoutput('/bin/sh -c "$HOME/.xui/bin/xui_lan_status.sh"')
        QtWidgets.QMessageBox.information(self, 'LAN Status', out or 'No network data.')

    def _save_manual_peers(self):
        manual = []
        for peer in self.peer_data.values():
            if peer.get('source') == 'manual':
                manual.append({
                    'name': peer.get('name') or peer.get('host'),
                    'host': peer.get('host'),
                    'port': int(peer.get('port') or 0),
                })
        safe_json_write(PEERS_FILE, {'manual_peers': manual})

    def _load_manual_peers(self):
        data = safe_json_read(PEERS_FILE, {'manual_peers': []})
        for peer in data.get('manual_peers', []):
            try:
                self._upsert_peer(
                    str(peer.get('name') or peer.get('host') or '').strip(),
                    str(peer.get('host') or '').strip(),
                    int(peer.get('port') or 0),
                    'manual',
                    persist=False,
                )
            except Exception:
                continue

    def _poll_events(self):
        while True:
            try:
                evt = self.engine.events.get_nowait()
            except queue.Empty:
                break
            kind = evt[0]
            if kind == 'status':
                self.status.setText(str(evt[1]))
                continue
            if kind == 'peer_up':
                _kind, key, name, host, port, source, node_id = evt
                self._upsert_peer(name, host, port, source, node_id)
                continue
            if kind == 'peer_down':
                _kind, key = evt
                peer = self.peer_data.get(key)
                if peer and peer.get('source') == 'LAN':
                    self._remove_peer(key)
                continue
            if kind == 'chat':
                _kind, name, host, port, text, _ts = evt
                if port and port > 0:
                    self._upsert_peer(name, host, int(port), 'LAN')
                self._append_msg(name, text)

    def closeEvent(self, e):
        try:
            self.timer.stop()
        except Exception:
            pass
        self.engine.stop()
        super().closeEvent(e)


def main():
    app = QtWidgets.QApplication([])
    app.setApplicationName('XUI Social Chat')
    w = SocialChatWindow()
    w.show()
    app.exec_()


if __name__ == '__main__':
    main()
PY
    chmod +x "$BIN_DIR/xui_social_chat.py"

    # LAN/P2P status helper
    cat > "$BIN_DIR/xui_lan_status.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
CHAT_PORT="${XUI_CHAT_PORT:-38600}"
DISC_PORT="${XUI_CHAT_DISCOVERY_PORT:-38655}"

echo "=== XUI LAN / P2P STATUS ==="
echo "Host: $(hostname)"
echo "User: $USER"
echo
echo "=== IPv4 interfaces ==="
ip -brief -4 addr 2>/dev/null || ip -4 addr show 2>/dev/null || true
echo
echo "=== Suggested peer IDs ==="
for ip in $(hostname -I 2>/dev/null); do
    [ -n "$ip" ] || continue
    echo "  $ip:$CHAT_PORT"
done
if ip -brief -4 addr show tailscale0 >/dev/null 2>&1; then
    TS_IP=$(ip -brief -4 addr show tailscale0 | awk '{print $3}' | cut -d/ -f1 | head -n1)
    [ -n "${TS_IP:-}" ] && echo "  $TS_IP:$CHAT_PORT (tailscale)"
fi
echo
ALL_IPS="$(hostname -I 2>/dev/null | xargs -n1 echo 2>/dev/null || true)"
if [ -n "${ALL_IPS:-}" ]; then
    NON_NAT="$(echo "$ALL_IPS" | grep -Ev '^10\.0\.2\.' || true)"
    if [ -z "${NON_NAT:-}" ]; then
        echo "Warning: only VirtualBox NAT range (10.0.2.x) detected."
        echo "LAN between VMs usually requires Bridged or Host-Only adapter."
        echo
    fi
fi

echo "=== Local listeners (chat/discovery) ==="
if command -v ss >/dev/null 2>&1; then
    ss -lun | awk -v p=":$DISC_PORT" '$0 ~ p' || true
    ss -ltn | awk -v p=":$CHAT_PORT" '$0 ~ p' || true
else
    netstat -uln 2>/dev/null | grep ":$DISC_PORT" || true
    netstat -ltn 2>/dev/null | grep ":$CHAT_PORT" || true
fi
echo

if command -v curl >/dev/null 2>&1; then
    PUB_IP=$(curl -4 -fsS --max-time 2 https://api.ipify.org 2>/dev/null || true)
    if [ -n "${PUB_IP:-}" ]; then
        echo "Public IP (approx): $PUB_IP"
    fi
fi
echo "UDP discovery port: $DISC_PORT"
echo "TCP chat port: $CHAT_PORT"
echo
echo "Internet mode:"
echo " - Best: Tailscale/ZeroTier (LAN over Internet)."
echo " - Direct: forward TCP $CHAT_PORT on your router."
BASH
    chmod +x "$BIN_DIR/xui_lan_status.sh"

    # Music player (simple)
        cat > "$BIN_DIR/xui_music.sh" <<'BASH'
#!/usr/bin/env bash
MUSIC_DIR="$HOME/Music"
if [ -n "$1" ]; then
    FILE="$1"
else
    FILE=$(find "$MUSIC_DIR" -type f \( -iname '*.mp3' -o -iname '*.ogg' -o -iname '*.wav' -o -iname '*.flac' \) | head -n1 || true)
fi
if [ -z "$FILE" ]; then echo "No music file"; exit 1; fi
if command -v mpv >/dev/null 2>&1; then
    exec mpv --really-quiet --fullscreen "$FILE"
elif command -v vlc >/dev/null 2>&1; then
    exec vlc --fullscreen --play-and-exit "$FILE"
else
    echo "No player"; exit 1
fi
BASH
    chmod +x "$BIN_DIR/xui_music.sh"

    # Brightness helper (requires sysfs)
    cat > "$BIN_DIR/xui_brightness.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
VAL=${1:-}
if [ -z "$VAL" ]; then
  echo "Usage: $0 <0-100|up|down>"
  exit 1
fi
if command -v brightnessctl >/dev/null 2>&1; then
  case "$VAL" in
    up) brightnessctl set +10% ;;
    down) brightnessctl set 10%- ;;
    *) brightnessctl set "${VAL}%" ;;
  esac
  exit 0
fi
if command -v xbacklight >/dev/null 2>&1; then
  case "$VAL" in
    up) xbacklight -inc 10 ;;
    down) xbacklight -dec 10 ;;
    *) xbacklight -set "$VAL" ;;
  esac
  exit 0
fi
echo "No brightness backend available (brightnessctl/xbacklight)"
exit 1
BASH
    chmod +x "$BIN_DIR/xui_brightness.sh"

    # Volume control helper
    cat > "$BIN_DIR/xui_volume.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if ! command -v pactl >/dev/null 2>&1; then
  echo "pactl not available"
  exit 1
fi
case ${1:-} in
    up) pactl set-sink-volume @DEFAULT_SINK@ +5% ;; 
    down) pactl set-sink-volume @DEFAULT_SINK@ -5% ;; 
    mute) pactl set-sink-mute @DEFAULT_SINK@ toggle ;; 
    get|"") pactl get-sink-volume @DEFAULT_SINK@; pactl get-sink-mute @DEFAULT_SINK@ ;;
    set) pactl set-sink-volume @DEFAULT_SINK@ "${2:-50}%";;
    *) echo "Usage: $0 {get|set <0-150>|up|down|mute}"; exit 1 ;;
esac
BASH
    chmod +x "$BIN_DIR/xui_volume.sh"

    # Simple HTTP server
    cat > "$BIN_DIR/xui_http_server.sh" <<'BASH'
#!/usr/bin/env bash
PORT=${1:-8000}
DIR=${2:-$HOME}
cd "$DIR"
python3 -m http.server "$PORT"
BASH
    chmod +x "$BIN_DIR/xui_http_server.sh"

    # SSH toggle
    cat > "$BIN_DIR/xui_ssh_toggle.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet ssh 2>/dev/null; then
  sudo systemctl stop ssh || true
  echo "ssh stopped"
elif command -v systemctl >/dev/null 2>&1; then
  sudo systemctl start ssh || true
  echo "ssh started"
else
  echo "systemctl unavailable"
  exit 1
fi
BASH
    chmod +x "$BIN_DIR/xui_ssh_toggle.sh"

    # Create desktop entries for some utilities
    cat > "$AUTOSTART_DIR/xui-sysmon.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=XUI System Monitor
Exec=$BIN_DIR/xui_sysmon.sh
Terminal=true
DESK
}

write_more_apps(){
        info "Writing additional apps: file manager, gallery, wifi/bluetooth toggles, gamepad test, calc, updater, retroarch launcher"

        # File manager launcher
        cat > "$BIN_DIR/xui_filemgr.sh" <<'BASH'
#!/usr/bin/env bash
launch_and_try_fullscreen() {
    "$@" &
    pid=$!
    if command -v xdotool >/dev/null 2>&1; then
        (
            sleep 0.8
            wid=$(xdotool search --onlyvisible --pid "$pid" 2>/dev/null | head -n1 || true)
            [ -n "$wid" ] && xdotool windowactivate "$wid" key F11 >/dev/null 2>&1 || true
        ) &
    fi
}
if command -v dolphin >/dev/null 2>&1; then
    launch_and_try_fullscreen dolphin "$@"
elif command -v pcmanfm >/dev/null 2>&1; then
    launch_and_try_fullscreen pcmanfm "$@"
elif command -v thunar >/dev/null 2>&1; then
    launch_and_try_fullscreen thunar "$@"
elif command -v nautilus >/dev/null 2>&1; then
    launch_and_try_fullscreen nautilus "$@"
elif command -v xdg-open >/dev/null 2>&1; then
    launch_and_try_fullscreen xdg-open "${1:-$HOME}"
else
    echo "No file manager found"; exit 1
fi
BASH
        chmod +x "$BIN_DIR/xui_filemgr.sh"

        # Gallery viewer
        cat > "$BIN_DIR/xui_gallery.sh" <<'BASH'
#!/usr/bin/env bash
DIR=${1:-$HOME/Pictures}
IMG=$(find "$DIR" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) | head -n1 || true)
if [ -z "$IMG" ]; then echo "No images found"; exit 1; fi
if command -v feh >/dev/null 2>&1; then feh -F "$DIR"; elif command -v sxiv >/dev/null 2>&1; then sxiv "$DIR"; elif command -v display >/dev/null 2>&1; then display "$IMG"; else echo "No image viewer installed"; exit 1; fi
BASH
        chmod +x "$BIN_DIR/xui_gallery.sh"

        # WiFi toggle
        cat > "$BIN_DIR/xui_wifi_toggle.sh" <<'BASH'
#!/usr/bin/env bash
if command -v nmcli >/dev/null 2>&1; then
    STATE=$(nmcli radio wifi)
    if [ "$STATE" = "enabled" ]; then nmcli radio wifi off; echo "wifi off"; else nmcli radio wifi on; echo "wifi on"; fi
else
    echo "nmcli not available"; exit 1
fi
BASH
        chmod +x "$BIN_DIR/xui_wifi_toggle.sh"

        # Bluetooth toggle
        cat > "$BIN_DIR/xui_bluetooth_toggle.sh" <<'BASH'
#!/usr/bin/env bash
if command -v bluetoothctl >/dev/null 2>&1; then
    POWER=$(bluetoothctl show | grep Powered | awk '{print $2}')
    if [ "$POWER" = "yes" ]; then bluetoothctl power off; echo "bluetooth off"; else bluetoothctl power on; echo "bluetooth on"; fi
else
    echo "bluetoothctl not found"; exit 1
fi
BASH
        chmod +x "$BIN_DIR/xui_bluetooth_toggle.sh"

        # Gamepad test launcher
        cat > "$BIN_DIR/xui_gamepad_test.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if command -v jstest-gtk >/dev/null 2>&1; then
    jstest-gtk &
elif command -v jstest >/dev/null 2>&1; then
    DEV=$(ls /dev/input/js* 2>/dev/null | head -n1 || true)
    if [ -n "$DEV" ]; then
        exec jstest "$DEV"
    fi
    echo "No /dev/input/js* device found"
    exit 1
elif command -v evtest >/dev/null 2>&1; then
    echo "Run manually with permissions: evtest"
    exit 1
else
    echo "No gamepad tester installed"
    exit 1
fi
BASH
        chmod +x "$BIN_DIR/xui_gamepad_test.sh"

        # Calculator
        cat > "$BIN_DIR/xui_calc.sh" <<'BASH'
#!/usr/bin/env bash
launch_and_try_fullscreen() {
    "$@" &
    pid=$!
    if command -v xdotool >/dev/null 2>&1; then
        (
            sleep 0.8
            wid=$(xdotool search --onlyvisible --pid "$pid" 2>/dev/null | head -n1 || true)
            [ -n "$wid" ] && xdotool windowactivate "$wid" key F11 >/dev/null 2>&1 || true
        ) &
    fi
}
if command -v gnome-calculator >/dev/null 2>&1; then
    launch_and_try_fullscreen gnome-calculator
elif command -v kcalc >/dev/null 2>&1; then
    launch_and_try_fullscreen kcalc
elif command -v gcalctool >/dev/null 2>&1; then
    launch_and_try_fullscreen gcalctool
elif command -v xterm >/dev/null 2>&1; then
    exec xterm -fullscreen -e bc -l
else
    echo "No calculator frontend found; install gnome-calculator/kcalc/xterm."
    exit 1
fi
BASH
        chmod +x "$BIN_DIR/xui_calc.sh"

        # System updater wrapper
        cat > "$BIN_DIR/xui_update_system.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${XUI_INSTALL_SYSTEM:-0}" != "1" ]; then
  echo "Run installer with --yes-install to allow system updates"
  exit 1
fi
if command -v apt >/dev/null 2>&1; then
  sudo apt update && sudo apt upgrade -y
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf upgrade -y
elif command -v pacman >/dev/null 2>&1; then
  sudo pacman -Syu --noconfirm
else
  echo "Unsupported package manager"
  exit 1
fi
BASH
        chmod +x "$BIN_DIR/xui_update_system.sh"

        # RetroArch installer
        cat > "$BIN_DIR/xui_install_retroarch.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
as_root(){
  if [ "$(id -u)" -eq 0 ]; then "$@"; return $?; fi
  if command -v sudo >/dev/null 2>&1; then sudo "$@"; return $?; fi
  echo "sudo required: $*" >&2
  return 1
}
wait_apt(){
  local t=0
  while pgrep -x apt >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 || pgrep -f unattended-upgrade >/dev/null 2>&1; do
    [ "$t" -ge 180 ] && break
    sleep 2
    t=$((t+2))
  done
}
ensure_flatpak(){
  if command -v flatpak >/dev/null 2>&1; then
    return 0
  fi
  if command -v apt >/dev/null 2>&1; then
    wait_apt
    as_root apt update || true
    wait_apt
    as_root apt install -y flatpak || true
  elif command -v dnf >/dev/null 2>&1; then
    as_root dnf install -y flatpak || true
  elif command -v pacman >/dev/null 2>&1; then
    as_root pacman -S --noconfirm flatpak || true
  fi
  command -v flatpak >/dev/null 2>&1
}
if command -v retroarch >/dev/null 2>&1; then
  echo "RetroArch already installed."
  exit 0
fi
if command -v flatpak >/dev/null 2>&1 && flatpak info org.libretro.RetroArch >/dev/null 2>&1; then
  echo "RetroArch (Flatpak) already installed."
  exit 0
fi
if command -v apt >/dev/null 2>&1; then
  wait_apt
  as_root apt update || true
  wait_apt
  as_root apt install -y retroarch || true
elif command -v dnf >/dev/null 2>&1; then
  as_root dnf install -y retroarch || true
elif command -v pacman >/dev/null 2>&1; then
  as_root pacman -S --noconfirm retroarch || true
fi
if ! command -v retroarch >/dev/null 2>&1; then
  ensure_flatpak || true
fi
if ! command -v retroarch >/dev/null 2>&1 && command -v flatpak >/dev/null 2>&1; then
  if ! flatpak remote-list | grep -q '^flathub'; then
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
  fi
  flatpak install -y flathub org.libretro.RetroArch || true
fi
if command -v retroarch >/dev/null 2>&1 || (command -v flatpak >/dev/null 2>&1 && flatpak info org.libretro.RetroArch >/dev/null 2>&1); then
  echo "RetroArch installed successfully."
  exit 0
fi
echo "RetroArch installation failed."
exit 1
BASH
        chmod +x "$BIN_DIR/xui_install_retroarch.sh"

        # RetroArch launcher
        cat > "$BIN_DIR/xui_retroarch.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
  shift || true
fi
has_retroarch(){
  command -v retroarch >/dev/null 2>&1 && return 0
  command -v flatpak >/dev/null 2>&1 && flatpak info org.libretro.RetroArch >/dev/null 2>&1 && return 0
  return 1
}
if [ "$CHECK_ONLY" = "1" ]; then
  has_retroarch && exit 0 || exit 1
fi
if command -v retroarch >/dev/null 2>&1; then
  exec retroarch "$@"
fi
if command -v flatpak >/dev/null 2>&1 && flatpak info org.libretro.RetroArch >/dev/null 2>&1; then
  exec flatpak run org.libretro.RetroArch "$@"
fi
echo "RetroArch not available."
echo "Run: $HOME/.xui/bin/xui_install_retroarch.sh"
exit 1
BASH
        chmod +x "$BIN_DIR/xui_retroarch.sh"

        # Lutris installer
        cat > "$BIN_DIR/xui_install_lutris.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
as_root(){
  if [ "$(id -u)" -eq 0 ]; then "$@"; return $?; fi
  if command -v sudo >/dev/null 2>&1; then sudo "$@"; return $?; fi
  echo "sudo required: $*" >&2
  return 1
}
wait_apt(){
  local t=0
  while pgrep -x apt >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 || pgrep -f unattended-upgrade >/dev/null 2>&1; do
    [ "$t" -ge 180 ] && break
    sleep 2
    t=$((t+2))
  done
}
ensure_flatpak(){
  if command -v flatpak >/dev/null 2>&1; then
    return 0
  fi
  if command -v apt >/dev/null 2>&1; then
    wait_apt
    as_root apt update || true
    wait_apt
    as_root apt install -y flatpak || true
  elif command -v dnf >/dev/null 2>&1; then
    as_root dnf install -y flatpak || true
  elif command -v pacman >/dev/null 2>&1; then
    as_root pacman -S --noconfirm flatpak || true
  fi
  command -v flatpak >/dev/null 2>&1
}
if command -v lutris >/dev/null 2>&1; then
  echo "Lutris already installed."
  exit 0
fi
if command -v flatpak >/dev/null 2>&1 && flatpak info net.lutris.Lutris >/dev/null 2>&1; then
  echo "Lutris (Flatpak) already installed."
  exit 0
fi
if command -v apt >/dev/null 2>&1; then
  wait_apt
  as_root apt update || true
  wait_apt
  as_root apt install -y lutris || true
elif command -v dnf >/dev/null 2>&1; then
  as_root dnf install -y lutris || true
elif command -v pacman >/dev/null 2>&1; then
  as_root pacman -S --noconfirm lutris || true
fi
if ! command -v lutris >/dev/null 2>&1; then
  ensure_flatpak || true
fi
if ! command -v lutris >/dev/null 2>&1 && command -v flatpak >/dev/null 2>&1; then
  if ! flatpak remote-list | grep -q '^flathub'; then
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
  fi
  flatpak install -y flathub net.lutris.Lutris || true
fi
if command -v lutris >/dev/null 2>&1 || (command -v flatpak >/dev/null 2>&1 && flatpak info net.lutris.Lutris >/dev/null 2>&1); then
  echo "Lutris installed successfully."
  exit 0
fi
echo "Lutris installation failed."
exit 1
BASH
        chmod +x "$BIN_DIR/xui_install_lutris.sh"

        # Lutris launcher
        cat > "$BIN_DIR/xui_lutris.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
  shift || true
fi
has_lutris(){
  command -v lutris >/dev/null 2>&1 && return 0
  command -v flatpak >/dev/null 2>&1 && flatpak info net.lutris.Lutris >/dev/null 2>&1 && return 0
  return 1
}
if [ "$CHECK_ONLY" = "1" ]; then
  has_lutris && exit 0 || exit 1
fi
if command -v lutris >/dev/null 2>&1; then
  exec lutris "$@"
fi
if command -v flatpak >/dev/null 2>&1 && flatpak info net.lutris.Lutris >/dev/null 2>&1; then
  exec flatpak run net.lutris.Lutris "$@"
fi
echo "Lutris not available."
echo "Run: $HOME/.xui/bin/xui_install_lutris.sh"
exit 1
BASH
        chmod +x "$BIN_DIR/xui_lutris.sh"

        # Heroic installer
        cat > "$BIN_DIR/xui_install_heroic.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
as_root(){
  if [ "$(id -u)" -eq 0 ]; then "$@"; return $?; fi
  if command -v sudo >/dev/null 2>&1; then sudo "$@"; return $?; fi
  echo "sudo required: $*" >&2
  return 1
}
wait_apt(){
  local t=0
  while pgrep -x apt >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 || pgrep -f unattended-upgrade >/dev/null 2>&1; do
    [ "$t" -ge 180 ] && break
    sleep 2
    t=$((t+2))
  done
}
ensure_flatpak(){
  if command -v flatpak >/dev/null 2>&1; then
    return 0
  fi
  if command -v apt >/dev/null 2>&1; then
    wait_apt
    as_root apt update || true
    wait_apt
    as_root apt install -y flatpak || true
  elif command -v dnf >/dev/null 2>&1; then
    as_root dnf install -y flatpak || true
  elif command -v pacman >/dev/null 2>&1; then
    as_root pacman -S --noconfirm flatpak || true
  fi
  command -v flatpak >/dev/null 2>&1
}
if command -v heroic >/dev/null 2>&1 || command -v heroic-games-launcher >/dev/null 2>&1; then
  echo "Heroic already installed."
  exit 0
fi
if command -v flatpak >/dev/null 2>&1 && flatpak info com.heroicgameslauncher.hgl >/dev/null 2>&1; then
  echo "Heroic (Flatpak) already installed."
  exit 0
fi
if command -v apt >/dev/null 2>&1; then
  wait_apt
  as_root apt update || true
  wait_apt
  as_root apt install -y heroic heroic-games-launcher || true
elif command -v dnf >/dev/null 2>&1; then
  as_root dnf install -y heroic-games-launcher || true
elif command -v pacman >/dev/null 2>&1; then
  as_root pacman -S --noconfirm heroic-games-launcher || true
fi
if ! command -v heroic >/dev/null 2>&1 && ! command -v heroic-games-launcher >/dev/null 2>&1; then
  ensure_flatpak || true
fi
if ! command -v heroic >/dev/null 2>&1 && ! command -v heroic-games-launcher >/dev/null 2>&1 && command -v flatpak >/dev/null 2>&1; then
  if ! flatpak remote-list | grep -q '^flathub'; then
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
  fi
  flatpak install -y flathub com.heroicgameslauncher.hgl || true
fi
if command -v heroic >/dev/null 2>&1 || command -v heroic-games-launcher >/dev/null 2>&1 || (command -v flatpak >/dev/null 2>&1 && flatpak info com.heroicgameslauncher.hgl >/dev/null 2>&1); then
  echo "Heroic installed successfully."
  exit 0
fi
echo "Heroic installation failed."
exit 1
BASH
        chmod +x "$BIN_DIR/xui_install_heroic.sh"

        # Heroic launcher
        cat > "$BIN_DIR/xui_heroic.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
  shift || true
fi
has_heroic(){
  command -v heroic >/dev/null 2>&1 && return 0
  command -v heroic-games-launcher >/dev/null 2>&1 && return 0
  command -v flatpak >/dev/null 2>&1 && flatpak info com.heroicgameslauncher.hgl >/dev/null 2>&1 && return 0
  return 1
}
if [ "$CHECK_ONLY" = "1" ]; then
  has_heroic && exit 0 || exit 1
fi
if command -v heroic >/dev/null 2>&1; then
  exec heroic "$@"
fi
if command -v heroic-games-launcher >/dev/null 2>&1; then
  exec heroic-games-launcher "$@"
fi
if command -v flatpak >/dev/null 2>&1 && flatpak info com.heroicgameslauncher.hgl >/dev/null 2>&1; then
  exec flatpak run com.heroicgameslauncher.hgl "$@"
fi
echo "Heroic not available."
echo "Run: $HOME/.xui/bin/xui_install_heroic.sh"
exit 1
BASH
        chmod +x "$BIN_DIR/xui_heroic.sh"

        # Games platform status
        cat > "$BIN_DIR/xui_platform_status.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
echo "=== XUI Games Platforms ==="
echo "steam: $("$HOME/.xui/bin/xui_steam.sh" --check >/dev/null 2>&1 && echo ready || echo missing)"
echo "retroarch: $("$HOME/.xui/bin/xui_retroarch.sh" --check >/dev/null 2>&1 && echo ready || echo missing)"
echo "lutris: $("$HOME/.xui/bin/xui_lutris.sh" --check >/dev/null 2>&1 && echo ready || echo missing)"
echo "heroic: $("$HOME/.xui/bin/xui_heroic.sh" --check >/dev/null 2>&1 && echo ready || echo missing)"
echo
echo "Compatibility:"
"$HOME/.xui/bin/xui_compat_status.sh" 2>/dev/null || true
BASH
        chmod +x "$BIN_DIR/xui_platform_status.sh"

        # Process monitor wrapper
        cat > "$BIN_DIR/xui_process_monitor.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if command -v htop >/dev/null 2>&1; then
    exec htop
fi
if command -v btop >/dev/null 2>&1; then
    exec btop
fi
exec top
BASH
        chmod +x "$BIN_DIR/xui_process_monitor.sh"

        # Network info summary
        cat > "$BIN_DIR/xui_netinfo.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
echo "=== Interfaces ==="
ip -brief addr 2>/dev/null || ip a
echo
echo "=== Routes ==="
ip route 2>/dev/null || true
echo
echo "=== DNS ==="
sed -n '1,6p' /etc/resolv.conf 2>/dev/null || true
BASH
        chmod +x "$BIN_DIR/xui_netinfo.sh"

        # Disk usage summary
        cat > "$BIN_DIR/xui_disk_usage.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
echo "=== Root filesystem ==="
df -h /
echo
echo "=== Home top usage ==="
du -h --max-depth=1 "$HOME" 2>/dev/null | sort -h | tail -n 20
BASH
        chmod +x "$BIN_DIR/xui_disk_usage.sh"

        # Restore newest backup automatically
        cat > "$BIN_DIR/xui_restore_last_backup.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
LAST=$(ls -1t "$HOME/.xui/backups"/xui-backup-*.tar.gz 2>/dev/null | head -n1 || true)
if [ -z "${LAST:-}" ]; then
    echo "No backups found in $HOME/.xui/backups"
    exit 1
fi
echo "Restoring: $LAST"
exec "$HOME/.xui/bin/xui_restore.sh" "$LAST"
BASH
        chmod +x "$BIN_DIR/xui_restore_last_backup.sh"

        # Logs viewer
        cat > "$BIN_DIR/xui_logs_view.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
LOGDIR="$HOME/.xui/logs"
mkdir -p "$LOGDIR"
echo "=== XUI logs in $LOGDIR ==="
ls -lah "$LOGDIR" 2>/dev/null || true
echo
TARGET="${1:-$LOGDIR/xui.log}"
if [ ! -f "$TARGET" ]; then
    TARGET=$(ls -1t "$LOGDIR"/*.log 2>/dev/null | head -n1 || true)
fi
if [ -z "${TARGET:-}" ] || [ ! -f "$TARGET" ]; then
    echo "No log file found."
    exit 1
fi
echo "Viewing: $TARGET"
if command -v less >/dev/null 2>&1; then
    exec less +G "$TARGET"
fi
tail -n 200 "$TARGET"
BASH
        chmod +x "$BIN_DIR/xui_logs_view.sh"

        # JSON browser helper
        cat > "$BIN_DIR/xui_json_browser.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
JSON_DIR="$HOME/.xui/data"
mkdir -p "$JSON_DIR"
echo "JSON files:"
mapfile -t files < <(find "$JSON_DIR" -maxdepth 2 -type f -name '*.json' | sort)
if [ "${#files[@]}" -eq 0 ]; then
    echo "No JSON files found in $JSON_DIR"
    exit 1
fi
i=1
for f in "${files[@]}"; do
    echo "[$i] $f"
    i=$((i+1))
done
echo
read -r -p "Select file number [1-${#files[@]}]: " idx
case "$idx" in
    ''|*[!0-9]*) echo "Invalid selection"; exit 1 ;;
esac
if [ "$idx" -lt 1 ] || [ "$idx" -gt "${#files[@]}" ]; then
    echo "Out of range"
    exit 1
fi
target="${files[$((idx-1))]}"
echo "=== $target ==="
python3 - "$target" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
try:
    data = json.loads(p.read_text())
    print(json.dumps(data, indent=2, ensure_ascii=False))
except Exception as e:
    print(f"Could not parse JSON: {e}")
    print(p.read_text()[:4000])
PY
BASH
        chmod +x "$BIN_DIR/xui_json_browser.sh"

        # Archive manager helper
        cat > "$BIN_DIR/xui_archive_tool.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
cmd=${1:-help}
case "$cmd" in
    pack)
        src=${2:-$HOME/.xui/data}
        out=${3:-$HOME/.xui/backups/custom-archive-$(date +%Y%m%d-%H%M%S).tar.gz}
        mkdir -p "$(dirname "$out")"
        tar -czf "$out" -C "$(dirname "$src")" "$(basename "$src")"
        echo "Packed: $out"
        ;;
    unpack)
        arc=${2:-}
        dst=${3:-$HOME/.xui/restored}
        [ -n "$arc" ] || { echo "Usage: $0 unpack <archive.tar.gz> [dest]"; exit 1; }
        mkdir -p "$dst"
        tar -xzf "$arc" -C "$dst"
        echo "Unpacked into: $dst"
        ;;
    list)
        arc=${2:-}
        [ -n "$arc" ] || { echo "Usage: $0 list <archive.tar.gz>"; exit 1; }
        tar -tzf "$arc"
        ;;
    *)
        echo "Usage:"
        echo "  $0 pack [source_dir] [output.tar.gz]"
        echo "  $0 unpack <archive.tar.gz> [dest_dir]"
        echo "  $0 list <archive.tar.gz>"
        exit 1
        ;;
esac
BASH
        chmod +x "$BIN_DIR/xui_archive_tool.sh"

        # Hash utility
        cat > "$BIN_DIR/xui_hash_tool.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
target=${1:-}
if [ -z "$target" ]; then
    read -r -p "File path or raw text: " target
fi
if [ -f "$target" ]; then
    echo "File: $target"
    sha256sum "$target" 2>/dev/null || true
    md5sum "$target" 2>/dev/null || true
    exit 0
fi
printf "%s" "$target" | sha256sum | awk '{print "sha256(text): " $1}'
printf "%s" "$target" | md5sum | awk '{print "md5(text): " $1}'
BASH
        chmod +x "$BIN_DIR/xui_hash_tool.sh"

        # Ping test
        cat > "$BIN_DIR/xui_ping_test.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
host=${1:-8.8.8.8}
ping -c 4 -W 2 "$host"
BASH
        chmod +x "$BIN_DIR/xui_ping_test.sh"

        # Docker status helper
        cat > "$BIN_DIR/xui_docker_status.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if ! command -v docker >/dev/null 2>&1; then
    echo "docker not installed"
    exit 1
fi
echo "=== docker version ==="
docker --version
echo
echo "=== docker ps ==="
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
BASH
        chmod +x "$BIN_DIR/xui_docker_status.sh"

        # VM status helper
        cat > "$BIN_DIR/xui_vm_status.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if command -v virsh >/dev/null 2>&1; then
    echo "=== libvirt domains ==="
    virsh list --all
    exit 0
fi
if command -v VBoxManage >/dev/null 2>&1; then
    echo "=== VirtualBox VMs ==="
    VBoxManage list vms
    exit 0
fi
echo "No VM manager detected (virsh/VirtualBox)."
exit 1
BASH
        chmod +x "$BIN_DIR/xui_vm_status.sh"

        # Service status helper
        cat > "$BIN_DIR/xui_service_status.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
echo "=== XUI user services ==="
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user --no-pager --type=service | grep -E 'xui-|UNIT|loaded|active' || true
else
    echo "systemctl not available"
fi
BASH
        chmod +x "$BIN_DIR/xui_service_status.sh"

        # App launcher
        cat > "$BIN_DIR/xui_app_launcher.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if command -v rofi >/dev/null 2>&1; then
    app=$(compgen -c | sort -u | rofi -dmenu -p "Run app")
    [ -n "${app:-}" ] && nohup "$app" >/dev/null 2>&1 &
    exit 0
fi
if command -v dmenu >/dev/null 2>&1; then
    app=$(compgen -c | sort -u | dmenu -p "Run app")
    [ -n "${app:-}" ] && nohup "$app" >/dev/null 2>&1 &
    exit 0
fi
echo "Install rofi or dmenu for app launcher."
exit 1
BASH
        chmod +x "$BIN_DIR/xui_app_launcher.sh"
}

write_even_more_apps(){
        info "Writing extra utilities: screenrec, clipboard, rclone backup, torrent, kodi, wallpaper, cron helper, emoji picker"

        # Screen recorder using ffmpeg
        cat > "$BIN_DIR/xui_screenrec.sh" <<'BASH'
#!/usr/bin/env bash
OUT_DIR="$HOME/.xui/assets/records"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/rec-$(date +%Y%m%d-%H%M%S).mkv"
FPS=${1:-25}
if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -video_size $(xdpyinfo | grep dimensions | awk '{print $2}') -framerate $FPS -f x11grab $DISPLAY -i ${DISPLAY:-:0} -f pulse -i default "$OUT"
    echo "$OUT"
else
    echo "ffmpeg not installed"; exit 1
fi
BASH
        chmod +x "$BIN_DIR/xui_screenrec.sh"

        # Clipboard manager wrapper (xclip/xsel)
        cat > "$BIN_DIR/xui_clip.sh" <<'BASH'
#!/usr/bin/env bash
case ${1:-get} in
    get)
        if command -v xclip >/dev/null 2>&1; then xclip -o -selection clipboard; elif command -v xsel >/dev/null 2>&1; then xsel --clipboard --output; else echo; fi
        ;;
    set)
        shift
        TEXT="$*"
        if command -v xclip >/dev/null 2>&1; then printf "%s" "$TEXT" | xclip -selection clipboard; elif command -v xsel >/dev/null 2>&1; then printf "%s" "$TEXT" | xsel --clipboard --input; else echo "no clipboard tool"; exit 1; fi
        ;;
    *) echo "Usage: $0 {get|set <text>}"; exit 1;;
esac
BASH
        chmod +x "$BIN_DIR/xui_clip.sh"

        # rclone backup wrapper
        cat > "$BIN_DIR/xui_rclone_backup.sh" <<'BASH'
#!/usr/bin/env bash
DEST=${1:-remote:backups}
SRC="$HOME/.xui"
if command -v rclone >/dev/null 2>&1; then
    rclone sync "$SRC" "$DEST" --progress
else
    echo "rclone not installed"; exit 1
fi
BASH
        chmod +x "$BIN_DIR/xui_rclone_backup.sh"

        # Torrent client launcher
        cat > "$BIN_DIR/xui_torrent.sh" <<'BASH'
#!/usr/bin/env bash
if command -v transmission-gtk >/dev/null 2>&1; then transmission-gtk "$@" & elif command -v qbittorrent >/dev/null 2>&1; then qbittorrent "$@" & else echo "No torrent client installed"; exit 1; fi
BASH
        chmod +x "$BIN_DIR/xui_torrent.sh"

        # Kodi launcher
        cat > "$BIN_DIR/xui_kodi.sh" <<'BASH'
#!/usr/bin/env bash
if command -v kodi >/dev/null 2>&1; then kodi "$@" & else echo "kodi not installed"; exit 1; fi
BASH
        chmod +x "$BIN_DIR/xui_kodi.sh"

        # Wallpaper setter (feh)
        cat > "$BIN_DIR/xui_wallpaper.sh" <<'BASH'
#!/usr/bin/env bash
IMG=${1:-}
if [ -z "$IMG" ]; then echo "Usage: $0 <image>"; exit 1; fi
if command -v feh >/dev/null 2>&1; then feh --bg-scale "$IMG"; else echo "feh not installed"; exit 1; fi
BASH
        chmod +x "$BIN_DIR/xui_wallpaper.sh"

        # Cron helper - list and edit user crontab
        cat > "$BIN_DIR/xui_cron.sh" <<'BASH'
#!/usr/bin/env bash
case ${1:-list} in
    list) crontab -l || echo "no crontab" ;;
    edit) crontab -e ;;
    *) echo "Usage: $0 {list|edit}"; exit 1;;
esac
BASH
        chmod +x "$BIN_DIR/xui_cron.sh"

        # Emoji picker via rofi (clipboard)
        cat > "$BIN_DIR/xui_emoji.sh" <<'BASH'
#!/usr/bin/env bash
EMOJI_FILE="$HOME/.xui/data/emoji.txt"
mkdir -p "$(dirname "$EMOJI_FILE")"
[ -f "$EMOJI_FILE" ] || cat > "$EMOJI_FILE" <<E
😀
🎮
🔥
💾
🎵
E
if command -v rofi >/dev/null 2>&1; then
    CH=$(cat "$EMOJI_FILE" | rofi -dmenu -p emoji)
    if [ -n "$CH" ]; then printf "%s" "$CH" | xclip -selection clipboard; fi
else
    echo "Install rofi to use emoji picker"; exit 1
fi
BASH
        chmod +x "$BIN_DIR/xui_emoji.sh"
}

write_battery_tools(){
        info "Writing battery saver, info, profiles and monitor"

        # Battery saver: reduce frequencies, dim audio, disable wifi/bluetooth
        cat > "$BIN_DIR/xui_battery_saver.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
ACTION=${1:-enable}
STATE_FILE="$HOME/.xui/data/battery_saver_on"

set_cpu_max(){
    val="$1"
    # prefer cpupower if available
    if command -v cpupower >/dev/null 2>&1; then
        cpupower frequency-set -u "${val}Hz" >/dev/null 2>&1 || true
        return
    fi
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        f="$cpu/cpufreq/scaling_max_freq"
        if [ -f "$f" ]; then
            if [ -w "$f" ]; then
                echo "$val" > "$f" || true
            else
                sudo sh -c "echo $val > $f" 2>/dev/null || true
            fi
        fi
    done
}

set_brightness_pct(){
    pct=${1:-25}
    # try brightnessctl, xbacklight, sysfs
    if command -v brightnessctl >/dev/null 2>&1; then
        brightnessctl set ${pct}% >/dev/null 2>&1 || true
        return
    fi
    if command -v xbacklight >/dev/null 2>&1; then
        xbacklight -set $pct >/dev/null 2>&1 || true
        return
    fi
    for d in /sys/class/backlight/*; do
        if [ -f "$d/brightness" ] && [ -f "$d/max_brightness" ]; then
            max=$(cat "$d/max_brightness")
            val=$((max * pct / 100))
            if [ -w "$d/brightness" ]; then
                echo "$val" > "$d/brightness" || true
            else
                sudo sh -c "echo $val > $d/brightness" 2>/dev/null || true
            fi
        fi
    done
}

mute_audio(){
    if command -v pactl >/dev/null 2>&1; then
        pactl set-sink-mute @DEFAULT_SINK@ 1 2>/dev/null || true
    elif command -v amixer >/dev/null 2>&1; then
        amixer -D pulse sset Master mute >/dev/null 2>&1 || true
    fi
}

unmute_audio(){
    if command -v pactl >/dev/null 2>&1; then
        pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null || true
    elif command -v amixer >/dev/null 2>&1; then
        amixer -D pulse sset Master unmute >/dev/null 2>&1 || true
    fi
}

disable_net_bt(){
    if command -v nmcli >/dev/null 2>&1; then nmcli radio wifi off >/dev/null 2>&1 || true; fi
    if command -v bluetoothctl >/dev/null 2>&1; then bluetoothctl power off >/dev/null 2>&1 || true; fi
}

enable_net_bt(){
    if command -v nmcli >/dev/null 2>&1; then nmcli radio wifi on >/dev/null 2>&1 || true; fi
    if command -v bluetoothctl >/dev/null 2>&1; then bluetoothctl power on >/dev/null 2>&1 || true; fi
}

case "$ACTION" in
    enable)
        mkdir -p "$(dirname "$STATE_FILE")"
        set_cpu_max 300000 || true
        set_brightness_pct 25 || true
        mute_audio || true
        disable_net_bt || true
        touch "$STATE_FILE" || true
        echo "Battery saver enabled"
        ;;
    disable)
        set_cpu_max 0 || true
        set_brightness_pct 85 || true
        unmute_audio || true
        enable_net_bt || true
        rm -f "$STATE_FILE" || true
        echo "Battery saver disabled"
        ;;
    toggle)
        if [ -f "$STATE_FILE" ]; then exec "$0" disable; else exec "$0" enable; fi
        ;;
    *) echo "Usage: $0 {enable|disable|toggle}"; exit 1;;
esac
BASH
        chmod +x "$BIN_DIR/xui_battery_saver.sh"

        # Battery info: show capacity, status and power/voltage if available
        cat > "$BIN_DIR/xui_battery_info.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if command -v upower >/dev/null 2>&1; then
    upower -e | while read -r dev; do
        upower -i "$dev" | awk '/percentage|state|voltage|time to/{print}'
    done
    exit 0
fi
for s in /sys/class/power_supply/*; do
    [ -d "$s" ] || continue
    name=$(basename "$s")
    if [ -f "$s/capacity" ]; then
        cap=$(cat "$s/capacity")
        stat=$(cat "$s/status" 2>/dev/null || echo Unknown)
        echo "$name: $cap% ($stat)"
    fi
    if [ -f "$s/voltage_now" ]; then
        v=$(cat "$s/voltage_now")
        echo "$name voltage: $v" 
    fi
done
BASH
        chmod +x "$BIN_DIR/xui_battery_info.sh"

        # Battery profiles: eco, balanced, performance
        cat > "$BIN_DIR/xui_battery_profile.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
PROFILE=${1:-balanced}
write_profile(){ echo "$1" > "$HOME/.xui/data/battery_profile" 2>/dev/null || true }
case "$PROFILE" in
    eco)
        # minimal
        setval=300000
        ;;
    balanced)
        setval=1150000
        ;;
    performance)
        # try to use maxfreq from CPU0
        if [ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq ]; then
            setval=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq)
        else
            setval=0
        fi
        ;;
    *) echo "Usage: $0 {eco|balanced|performance}"; exit 1;;
esac
if [ "$setval" -ne 0 ]; then
    if command -v cpupower >/dev/null 2>&1; then
        cpupower frequency-set -u "${setval}Hz" >/dev/null 2>&1 || true
    else
        for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
            f="$cpu/cpufreq/scaling_max_freq"
            if [ -f "$f" ]; then
                if [ -w "$f" ]; then
                    echo "$setval" > "$f" || true
                else
                    sudo sh -c "echo $setval > $f" 2>/dev/null || true
                fi
            fi
        done
    fi
fi
write_profile "$PROFILE"
echo "Profile set to $PROFILE"
BASH
        chmod +x "$BIN_DIR/xui_battery_profile.sh"

        # Battery monitor: Python small script that watches capacity and enables saver below threshold
        cat > "$BIN_DIR/xui_battery_monitor.py" <<'PY'
#!/usr/bin/env python3
import time, os, subprocess, logging
XUI=os.path.expanduser('~/.xui')
logging.basicConfig(filename=os.path.join(XUI,'logs','battery_monitor.log'), level=logging.INFO, format='%(asctime)s %(message)s')
THRESHOLD=int(os.environ.get('XUI_BATTERY_THRESHOLD','20'))
CHECK=int(os.environ.get('XUI_BATTERY_CHECK_SEC','60'))

def read_capacity():
    # try sysfs
    for base in ['/sys/class/power_supply']:
        if os.path.isdir(base):
            for s in os.listdir(base):
                p=os.path.join(base,s,'capacity')
                if os.path.exists(p):
                    try:
                        return int(open(p).read().strip())
                    except Exception:
                        continue
    # fallback to upower
    try:
        out=subprocess.check_output(['upower','-e'], text=True)
        for dev in out.splitlines():
            try:
                info=subprocess.check_output(['upower','-i',dev], text=True)
                for line in info.splitlines():
                    line=line.strip()
                    if line.startswith('percentage:'):
                        return int(line.split()[1].strip('%'))
            except Exception:
                continue
    except Exception:
        pass
    return None

def is_charging():
    for base in ['/sys/class/power_supply']:
        if os.path.isdir(base):
            for s in os.listdir(base):
                p=os.path.join(base,s,'status')
                if os.path.exists(p):
                    try:
                        st=open(p).read().strip().lower()
                        if 'charging' in st:
                            return True
                    except Exception:
                        continue
    try:
        out=subprocess.check_output(['upower','-i',subprocess.check_output(['upower','-e']).splitlines()[0]], text=True)
        for line in out.splitlines():
            if 'state:' in line:
                if 'charging' in line.lower():
                    return True
    except Exception:
        pass
    return False

def enable_saver():
    subprocess.run([os.path.join(XUI,'bin','xui_battery_saver.sh'),'enable'])
def disable_saver():
    subprocess.run([os.path.join(XUI,'bin','xui_battery_saver.sh'),'disable'])

def main():
    saver_on=False
    logging.info('battery monitor started, threshold=%s, check=%s', THRESHOLD, CHECK)
    while True:
        try:
            cap=read_capacity()
            ch=is_charging()
            logging.debug('cap=%s charging=%s saver_on=%s', cap, ch, saver_on)
            if cap is not None:
                if cap<=THRESHOLD and not ch and not saver_on:
                    logging.info('capacity %s <= %s, enabling saver', cap, THRESHOLD)
                    enable_saver(); saver_on=True
                if ch and saver_on:
                    logging.info('charging detected, disabling saver')
                    disable_saver(); saver_on=False
        except Exception as e:
            logging.exception('monitor loop error: %s', e)
        time.sleep(CHECK)

if __name__=='__main__':
    main()
PY
        chmod +x "$BIN_DIR/xui_battery_monitor.py"

        # Systemd user unit to run monitor
        cat > "$SYSTEMD_USER_DIR/xui-battery-monitor.service" <<UNIT
[Unit]
Description=XUI Battery Monitor

[Service]
Type=simple
ExecStart=%h/.xui/bin/xui_battery_monitor.py
Restart=on-failure

[Install]
WantedBy=default.target
UNIT

}


finish_setup(){
  info "Finalizing installation"
  # make sure everything is executable
  chmod -R a+x "$BIN_DIR" || true
  chmod +x "$DASH_DIR/pyqt_dashboard_improved.py" || true
  chmod +x "$DASH_DIR/pyqt_dashboard.py" || true
  chmod +x "$BIN_DIR/xui_joy_listener.py" || true
  touch "$XUI_DIR/.xui_4_0xv_setup_done"
  info "Configuring autostart for each login"
  mkdir -p "$AUTOSTART_DIR" "$SYSTEMD_USER_DIR" || true
  if [ -f "$AUTOSTART_DIR/xui-dashboard.desktop" ]; then
    info "Autostart desktop entry ready: $AUTOSTART_DIR/xui-dashboard.desktop"
  else
    warn "Autostart desktop entry missing: $AUTOSTART_DIR/xui-dashboard.desktop"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl --user daemon-reload >/dev/null 2>&1; then
      systemctl --user enable --now xui-dashboard.service xui-joy.service || true
      systemctl --user enable --now xui-battery-monitor.service || true
      info "Attempted to enable user services: xui-dashboard, xui-joy, xui-battery-monitor"
    else
      warn "systemctl --user daemon-reload failed; using desktop autostart only"
    fi
  fi
  info "Installation complete."
}

main(){
  parse_args "$@"
  info "Starting XUI Ultra Master installer"
  ensure_dirs
  install_dependencies
    install_browser
  create_basics
    post_create_assets
  write_dashboard_py
  deploy_custom_dashboard
    write_apps_utilities
    write_more_apps
  write_joy_py
  write_extras
  write_systemd_and_autostart
  write_enable_autostart_script
    # Additional utilities
    write_logger_and_helpers
    write_backup_restore
    write_diagnostics
    write_profiles_manager
    write_plugins_skeleton
    write_auto_update
    write_uninstall
    write_readme_and_requirements
    write_basic_tests
        write_web_control
        write_theme_toggle
        install_compat_layer
        write_battery_tools
        write_even_more_apps
  finish_setup
  if confirm "Do you want to launch the dashboard now?"; then
    "$BIN_DIR/xui_start.sh"
  fi
}

main "$@"
