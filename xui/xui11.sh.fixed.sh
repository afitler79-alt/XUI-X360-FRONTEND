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
    if [ "${XUI_NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
        if check_cmd pkexec; then
            pkexec "$@"
            return $?
        fi
        if check_cmd sudo; then
            sudo -n "$@"
            return $?
        fi
    else
        if check_cmd sudo; then
            sudo "$@"
            return $?
        fi
        if check_cmd pkexec; then
            pkexec "$@"
            return $?
        fi
    fi
    warn "root privileges unavailable; cannot run: $*"
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

# Install APT packages one by one and continue on errors.
apt_install_each_best_effort(){
    local pkg
    local failed=0
    for pkg in "$@"; do
        if ! apt_safe_install "$pkg"; then
            warn "Failed apt package: $pkg"
            failed=1
        fi
    done
    return "$failed"
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
        local core_pkgs optional_pkgs
        arch_now="$(uname -m)"
        core_pkgs=(
            python3 python3-pip python3-venv python3-pyqt5
            python3-pyqt5.qtmultimedia python3-pyqt5.qtgamepad
            python3-pil python3-evdev
        )
        optional_pkgs=(
            ffmpeg mpv jq xdotool curl ca-certificates iproute2 bc
            xclip xsel rofi feh maim scrot udisks2 p7zip-full joystick joycond evtest jstest-gtk xboxdrv
            retroarch lutris kodi
            binutils file xz-utils
            libc6 libstdc++6 libgcc-s1 libasound2 libx11-6 libxrandr2 libxinerama1 libxcursor1 libxi6
            libgl1 libglu1-mesa libpulse0 mesa-vulkan-drivers
            steam-installer steam
        )
        apt_safe_update || warn "apt update failed"
        # Install critical runtime first (must succeed for dashboard)
        if ! apt_safe_install "${core_pkgs[@]}"; then
            warn "Core apt dependencies failed in bulk install; retrying one by one"
            apt_install_each_best_effort "${core_pkgs[@]}" || warn "Some core apt dependencies are still missing"
        fi
        apt_safe_install python3-pyqt5.qtwebengine || warn "Optional apt package missing: python3-pyqt5.qtwebengine"
        apt_install_each_best_effort qml-module-qtgamepad libqt5gamepad5 || true
        # Optional tools (can fail without breaking dashboard runtime)
        if ! apt_safe_install "${optional_pkgs[@]}"; then
            warn "Optional apt packages failed in bulk install; retrying one by one"
            apt_install_each_best_effort "${optional_pkgs[@]}" || warn "Some optional apt packages are still missing"
        fi
        # Windows compatibility (best effort): Wine + Winetricks + ARM helpers
        if [ "$arch_now" = "x86_64" ] || [ "$arch_now" = "amd64" ]; then
            apt_install_each_best_effort wine wine64 winetricks || warn "Wine/Winetricks install failed on x86_64"
        elif [ "$arch_now" = "aarch64" ] || [ "$arch_now" = "arm64" ]; then
            apt_install_each_best_effort wine64 winetricks || true
            apt_install_each_best_effort box64 box86 qemu-user-static || warn "ARM compatibility packages failed (box64/box86/qemu)"
            info "AArch64 detected: x86 Windows .exe may need box64 + x86 Wine build"
        fi
        # Optional gaming/compat packages (best effort one by one)
        for pkg in flatpak steam-installer steamcmd box64 box86 qemu-user-static retroarch lutris heroic heroic-games-launcher joycond; do
            apt_safe_install "$pkg" || true
        done
    elif command -v dnf >/dev/null 2>&1; then
        run_as_root dnf install -y \
            python3 python3-pip python3-virtualenv python3-qt5 python3-pillow python3-evdev \
            ffmpeg mpv jq xdotool curl iproute bc \
            xclip xsel rofi feh scrot udisks2 p7zip joystick joycond retroarch lutris kodi || warn "Some dnf packages failed to install"
        run_as_root dnf install -y python3-qt5-webengine || true
        for pkg in python3-qt5-gamepad qt5-qtgamepad qt5-qtgamepad-devel; do
            run_as_root dnf install -y "$pkg" || true
        done
        run_as_root dnf install -y wine winetricks || true
        for pkg in flatpak steam box64 fex-emu qemu-user-static retroarch lutris heroic-games-launcher joycond; do
            run_as_root dnf install -y "$pkg" || true
        done
    elif command -v pacman >/dev/null 2>&1; then
        run_as_root pacman -Syu --noconfirm \
            python python-pip python-virtualenv pyqt5 python-pillow python-evdev \
            ffmpeg mpv jq xdotool curl iproute2 bc \
            xclip xsel rofi feh scrot maim udisks2 p7zip joystick joycond retroarch lutris kodi || warn "Some pacman packages failed to install"
        run_as_root pacman -S --noconfirm python-pyqt5-webengine || true
        for pkg in qt5-gamepad; do
            run_as_root pacman -S --noconfirm "$pkg" || true
        done
        run_as_root pacman -S --noconfirm wine winetricks || true
        for pkg in flatpak steam box64 qemu-user-static retroarch lutris heroic-games-launcher joycond; do
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
    XUI_ONLY_REFRESH_STORE=0
    XUI_ONLY_REFRESH_CONTROLLERS=0
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
            --refresh-store-ui|--fix-store-ui)
                XUI_ONLY_REFRESH_STORE=1
                shift
                ;;
            --refresh-controllers|--fix-controllers)
                XUI_ONLY_REFRESH_CONTROLLERS=1
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [--yes-install|-y] [--no-auto-install] [--use-external-dashboard] [--skip-apt-wait] [--apt-wait-seconds N] [--refresh-store-ui] [--refresh-controllers]"; exit 0 ;;
            *)
                warn "Ignoring unknown argument: $1"
                shift
                ;;
        esac
    done
    export AUTO_INSTALL_TOOLS XUI_INSTALL_SYSTEM XUI_USE_EXTERNAL_DASHBOARD XUI_SKIP_APT_WAIT XUI_APT_WAIT_SECONDS XUI_ONLY_REFRESH_STORE XUI_ONLY_REFRESH_CONTROLLERS
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
  if [ "${XUI_NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
    if command -v pkexec >/dev/null 2>&1; then pkexec "$@"; return $?; fi
    if command -v sudo >/dev/null 2>&1; then sudo -n "$@"; return $?; fi
  else
    if command -v sudo >/dev/null 2>&1; then sudo "$@"; return $?; fi
    if command -v pkexec >/dev/null 2>&1; then pkexec "$@"; return $?; fi
  fi
  echo "root privileges unavailable: $*" >&2
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
  if [ "${XUI_NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
    if command -v pkexec >/dev/null 2>&1; then pkexec "$@"; return $?; fi
    if command -v sudo >/dev/null 2>&1; then sudo -n "$@"; return $?; fi
  else
    if command -v sudo >/dev/null 2>&1; then sudo "$@"; return $?; fi
    if command -v pkexec >/dev/null 2>&1; then pkexec "$@"; return $?; fi
  fi
  echo "root privileges unavailable: $*" >&2
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
  if [ "${XUI_NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
    if command -v pkexec >/dev/null 2>&1; then pkexec "$@"; return $?; fi
    if command -v sudo >/dev/null 2>&1; then sudo -n "$@"; return $?; fi
  else
    if command -v sudo >/dev/null 2>&1; then sudo "$@"; return $?; fi
    if command -v pkexec >/dev/null 2>&1; then pkexec "$@"; return $?; fi
  fi
  echo "root privileges unavailable: $*" >&2
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

    # Generate startup.mp4 via ffmpeg if missing
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
import urllib.request
import urllib.parse
import urllib.error
from pathlib import Path
from PyQt5 import QtWidgets, QtGui, QtCore
try:
    from PyQt5 import QtWebEngineWidgets
except Exception:
    QtWebEngineWidgets = None
try:
    from PyQt5 import QtGamepad
except Exception:
    QtGamepad = None

ASSETS = Path.home() / '.xui' / 'assets'
XUI_HOME = Path.home() / '.xui'
DATA_HOME = XUI_HOME / 'data'
RECENT_FILE = DATA_HOME / 'recent.json'
FRIENDS_FILE = DATA_HOME / 'friends.json'
PROFILE_FILE = DATA_HOME / 'profile.json'
PEERS_FILE = DATA_HOME / 'social_peers.json'
WORLD_CHAT_FILE = DATA_HOME / 'world_chat.json'
SOCIAL_MESSAGES_FILE = DATA_HOME / 'social_messages_recent.json'
FRIEND_REQUESTS_FILE = DATA_HOME / 'friend_requests.json'

sys.path.insert(0, str(XUI_HOME / 'bin'))
try:
    from xui_game_lib import unlock_for_event, ensure_achievements
except Exception:
    def unlock_for_event(*_args, **_kwargs):
        return []

    def ensure_achievements(*_args, **_kwargs):
        return {'items': [], 'unlocked': []}


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
    once_flag = DATA_HOME / 'startup_video_once.flag'
    try:
        sid = os.environ.get('XDG_SESSION_ID', '').strip() or str(os.getpid())
        if once_flag.exists():
            prev = once_flag.read_text(encoding='utf-8', errors='ignore').strip()
            if prev == sid:
                return
        once_flag.parent.mkdir(parents=True, exist_ok=True)
        once_flag.write_text(sid, encoding='utf-8')
    except Exception:
        pass
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
    if not FRIEND_REQUESTS_FILE.exists():
        FRIEND_REQUESTS_FILE.write_text('[]')


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
        self.world_relay = os.environ.get('XUI_WORLD_RELAY_URL', 'https://ntfy.sh').strip().rstrip('/')
        self.world_topic = self._sanitize_topic(
            os.environ.get('XUI_WORLD_TOPIC', 'xui-world-global')
        )
        self.world_enabled = True
        self.events = queue.Queue()
        self.running = False
        self.threads = []
        self.peers = {}
        self.lock = threading.Lock()
        self.local_ips = set(local_ipv4_addresses())
        self._seen_world_ids = set()

    def _sanitize_topic(self, text):
        raw = ''.join(ch.lower() if ch.isalnum() or ch in ('-', '_', '.') else '-' for ch in str(text or '').strip())
        while '--' in raw:
            raw = raw.replace('--', '-')
        raw = raw.strip('-._')
        return raw or 'xui-world-global'

    def set_world_topic(self, topic):
        new_topic = self._sanitize_topic(topic)
        if new_topic == self.world_topic:
            return
        self.world_topic = new_topic
        self._seen_world_ids.clear()
        self.events.put(('world_room', self.world_topic))
        self.events.put(('status', f'World chat room set to: {self.world_topic}'))

    def set_world_enabled(self, enabled):
        self.world_enabled = bool(enabled)
        self.events.put(('world_status', self.world_enabled, self.world_topic))
        if self.world_enabled:
            self.events.put(('status', f'World chat connected: {self.world_topic}'))
        else:
            self.events.put(('status', 'World chat disconnected'))

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
        for fn in (
            self._tcp_server_loop,
            self._udp_discovery_listener,
            self._udp_discovery_sender,
            self._peer_gc_loop,
            self._world_recv_loop,
        ):
            t = threading.Thread(target=fn, daemon=True)
            self.threads.append(t)
            t.start()
        if self.chat_port:
            self.events.put(('status', f'Chat TCP listening on port {self.chat_port}'))
        else:
            self.events.put(('status', 'No free TCP chat port available'))
        self.events.put(('world_status', self.world_enabled, self.world_topic))

    def stop(self):
        self.running = False
        for t in self.threads:
            t.join(timeout=0.2)

    def _send_packet(self, host, port, payload):
        body = (json.dumps(payload, ensure_ascii=False) + '\n').encode('utf-8', errors='ignore')
        with socket.create_connection((str(host), int(port)), timeout=4.0) as s:
            s.sendall(body)

    def send_chat(self, host, port, text):
        payload = {
            'type': 'chat',
            'node_id': self.node_id,
            'from': self.nickname,
            'text': str(text),
            'ts': time.time(),
            'reply_port': int(self.chat_port or 0),
        }
        self._send_packet(host, port, payload)

    def send_private_message(self, host, port, text):
        payload = {
            'type': 'private_message',
            'node_id': self.node_id,
            'from': self.nickname,
            'text': str(text),
            'ts': time.time(),
            'reply_port': int(self.chat_port or 0),
        }
        self._send_packet(host, port, payload)

    def send_friend_request(self, host, port, note=''):
        payload = {
            'type': 'friend_request',
            'node_id': self.node_id,
            'from': self.nickname,
            'note': str(note or 'XUI friend request'),
            'ts': time.time(),
            'reply_port': int(self.chat_port or 0),
        }
        self._send_packet(host, port, payload)

    def _world_url(self, suffix=''):
        topic = urllib.parse.quote(self.world_topic, safe='')
        return f'{self.world_relay}/{topic}{suffix}'

    def send_world_chat(self, text):
        msg = {
            'kind': 'xui_world_chat',
            'node_id': self.node_id,
            'from': self.nickname,
            'text': str(text or ''),
            'room': self.world_topic,
            'ts': time.time(),
        }
        data = json.dumps(msg, ensure_ascii=False).encode('utf-8', errors='ignore')
        req = urllib.request.Request(
            self._world_url(''),
            data=data,
            method='POST',
            headers={
                'Content-Type': 'text/plain; charset=utf-8',
                'User-Agent': 'xui-dashboard-world-chat',
                'X-Title': f'XUI:{self.nickname}',
            },
        )
        with urllib.request.urlopen(req, timeout=8) as r:
            _ = r.read(256)

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
                mtype = str(msg.get('type') or '')
                if mtype not in ('chat', 'private_message', 'friend_request'):
                    continue
                sender = str(msg.get('from') or host)
                text = str(msg.get('text') or '').strip()
                note = str(msg.get('note') or '').strip()
                sender_node = str(msg.get('node_id') or '')
                try:
                    reply_port = int(msg.get('reply_port') or 0)
                except Exception:
                    reply_port = 0
                if reply_port > 0:
                    self._upsert_peer(sender, host, reply_port, 'LAN', sender_node)
                if mtype == 'friend_request':
                    self.events.put(('friend_request', sender, host, int(reply_port or 0), note))
                    continue
                if text and mtype == 'private_message':
                    self.events.put(('private_message', sender, text))
                    continue
                if text:
                    self.events.put(('chat', sender, text))
        srv.close()

    def _world_recv_loop(self):
        backoff = 1.2
        while self.running:
            if not self.world_enabled:
                time.sleep(0.4)
                continue
            url = self._world_url('/json')
            req = urllib.request.Request(
                url,
                headers={
                    'User-Agent': 'xui-dashboard-world-chat',
                    'Cache-Control': 'no-cache',
                    'Connection': 'keep-alive',
                },
            )
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    backoff = 1.2
                    while self.running and self.world_enabled:
                        raw = resp.readline()
                        if not raw:
                            break
                        line = raw.decode('utf-8', errors='ignore').strip()
                        if not line:
                            continue
                        try:
                            evt = json.loads(line)
                        except Exception:
                            continue
                        if str(evt.get('event') or '') != 'message':
                            continue
                        msg_id = str(evt.get('id') or '')
                        if msg_id:
                            if msg_id in self._seen_world_ids:
                                continue
                            self._seen_world_ids.add(msg_id)
                            if len(self._seen_world_ids) > 1200:
                                self._seen_world_ids = set(list(self._seen_world_ids)[-600:])
                        body = str(evt.get('message') or '').strip()
                        if not body:
                            continue
                        try:
                            payload = json.loads(body)
                        except Exception:
                            payload = {
                                'kind': 'xui_world_chat',
                                'node_id': '',
                                'from': str(evt.get('title') or 'WORLD'),
                                'text': body,
                                'room': self.world_topic,
                                'ts': evt.get('time', time.time()),
                            }
                        if str(payload.get('kind') or '') != 'xui_world_chat':
                            continue
                        if str(payload.get('room') or self.world_topic) != self.world_topic:
                            continue
                        if str(payload.get('node_id') or '') == self.node_id:
                            continue
                        who = str(payload.get('from') or 'WORLD')
                        txt = str(payload.get('text') or '').strip()
                        if txt:
                            self.events.put(('world_chat', who, txt))
            except Exception as exc:
                self.events.put(('status', f'World relay reconnecting: {exc}'))
                time.sleep(min(8.0, backoff))
                backoff = min(8.0, backoff * 1.5)


class SocialOverlay(QtWidgets.QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.nickname = current_gamertag()
        self.engine = InlineSocialEngine(self.nickname)
        self.peer_items = {}
        self.peer_data = {}
        self.friends = []
        self.friend_requests = []
        self.setModal(True)
        self.setWindowFlags(QtCore.Qt.Dialog | QtCore.Qt.FramelessWindowHint)
        self.setAttribute(QtCore.Qt.WA_TranslucentBackground, True)
        self._build()
        self._load_friends()
        self._load_friend_requests()
        self._load_manual_peers()
        self._load_world_settings()
        self.engine.start()
        self._refresh_world_peer()
        self.timer = QtCore.QTimer(self)
        self.timer.timeout.connect(self._poll_events)
        self.timer.start(120)
        self._append_system('LAN autodiscovery enabled (broadcast + probe). Add peer for Internet P2P.')
        self._append_system(f"World chat ready via relay ({self.engine.world_relay}) room: {self.engine.world_topic}")

    def _build(self):
        self._vk_opening = False
        self._vk_last_close = 0.0
        self._action_items = {}
        self.setStyleSheet('''
            QFrame#social_panel {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #313740, stop:1 #1a2028);
                border:2px solid rgba(214,223,235,0.52);
                border-radius:7px;
            }
            QFrame#social_col {
                background:rgba(52,61,72,0.92);
                border:1px solid rgba(196,208,222,0.32);
            }
            QLabel#social_title { color:#f3f7f7; font-size:28px; font-weight:800; }
            QLabel#social_hint { color:rgba(237,243,247,0.82); font-size:15px; }
            QLabel#social_col_title { color:#ecf3f8; font-size:20px; font-weight:800; }
            QListWidget {
                background:rgba(236,239,242,0.92);
                color:#20252b;
                border:1px solid rgba(0,0,0,0.26);
                font-size:24px;
                outline:none;
            }
            QListWidget::item {
                padding:6px 10px;
                border:1px solid transparent;
            }
            QListWidget::item:selected {
                color:#f3fff2;
                background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #4ea93f, stop:1 #2f8832);
                border:1px solid rgba(255,255,255,0.25);
            }
            QPlainTextEdit {
                background:rgba(228,233,238,0.96);
                border:1px solid rgba(32,39,48,0.28);
                color:#17202a;
                font-size:18px;
            }
            QLineEdit {
                background:#eef2f6;
                border:1px solid #8fa0b1;
                color:#17202a;
                font-size:21px;
                font-weight:700;
                padding:8px;
            }
            QPushButton {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #4ea93f, stop:1 #2f8832);
                color:#efffee;
                border:1px solid rgba(255,255,255,0.2);
                font-size:17px;
                font-weight:700;
                padding:8px 12px;
            }
            QPushButton:hover { background:#58b449; }
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
        body.setSpacing(10)

        left_wrap = QtWidgets.QFrame()
        left_wrap.setObjectName('social_col')
        left = QtWidgets.QVBoxLayout(left_wrap)
        left.setContentsMargins(8, 8, 8, 8)
        left.setSpacing(6)
        left_lbl = QtWidgets.QLabel('Messages / Peers')
        left_lbl.setObjectName('social_col_title')
        self.peers = QtWidgets.QListWidget()
        self.peers.setMinimumWidth(340)
        left.addWidget(left_lbl)
        left.addWidget(self.peers, 1)

        center_wrap = QtWidgets.QFrame()
        center_wrap.setObjectName('social_col')
        center = QtWidgets.QVBoxLayout(center_wrap)
        center.setContentsMargins(8, 8, 8, 8)
        center.setSpacing(6)
        center_lbl = QtWidgets.QLabel('Actions')
        center_lbl.setObjectName('social_col_title')
        self.actions = QtWidgets.QListWidget()
        self.actions.setMinimumWidth(290)
        center.addWidget(center_lbl)
        center.addWidget(self.actions, 1)

        right_wrap = QtWidgets.QFrame()
        right_wrap.setObjectName('social_col')
        right = QtWidgets.QVBoxLayout(right_wrap)
        right.setContentsMargins(8, 8, 8, 8)
        right.setSpacing(6)
        right_lbl = QtWidgets.QLabel('Message Detail')
        right_lbl.setObjectName('social_col_title')
        self.peer_meta = QtWidgets.QLabel('Select a peer to chat.')
        self.peer_meta.setObjectName('social_hint')
        self.chat = QtWidgets.QPlainTextEdit()
        self.chat.setReadOnly(True)
        self.input = QtWidgets.QLineEdit()
        self.input.setPlaceholderText('Press A/ENTER to type message...')
        self.input.installEventFilter(self)
        self.btn_send = QtWidgets.QPushButton('Send')
        self.btn_send.clicked.connect(self._send_current)
        self.input.returnPressed.connect(self._send_current)
        send_row = QtWidgets.QHBoxLayout()
        send_row.addWidget(self.input, 1)
        send_row.addWidget(self.btn_send)
        self.status = QtWidgets.QLabel('Ready')
        self.status.setObjectName('social_hint')
        right.addWidget(right_lbl)
        right.addWidget(self.peer_meta)
        right.addWidget(self.chat, 1)
        right.addLayout(send_row)
        right.addWidget(self.status)

        body.addWidget(left_wrap, 3)
        body.addWidget(center_wrap, 2)
        body.addWidget(right_wrap, 5)
        root.addLayout(body, 1)

        self._add_action_item('reply', 'Reply / Send Message')
        self._add_action_item('friend_request', 'Send Friend Request')
        self._add_action_item('friend_requests', 'Friend Requests')
        self._add_action_item('friends', 'Friends List')
        self._add_action_item('voice_call_hub', 'Voice/Call Hub')
        self._add_action_item('add_peer', 'Add Peer ID')
        self._add_action_item('peer_ids', 'My Peer IDs')
        self._add_action_item('lan_status', 'LAN Status')
        self._add_action_item('world_toggle', 'World Chat: ON')
        self._add_action_item('world_room', 'World Room')
        if self.actions.count() > 0:
            self.actions.setCurrentRow(0)
        self.actions.itemActivated.connect(self._run_selected_action)
        self.actions.itemDoubleClicked.connect(self._run_selected_action)
        self.peers.currentItemChanged.connect(lambda *_: self._update_peer_meta())

        bottom = QtWidgets.QLabel('A/ENTER = select | B/ESC = close | X = quick send | Text input opens virtual keyboard')
        bottom.setObjectName('social_hint')
        root.addWidget(bottom)

    def _add_action_item(self, key, text):
        it = QtWidgets.QListWidgetItem(str(text))
        it.setData(QtCore.Qt.UserRole, str(key))
        self.actions.addItem(it)
        self._action_items[str(key)] = it

    def _run_selected_action(self, *_):
        it = self.actions.currentItem()
        if it is None:
            return
        key = str(it.data(QtCore.Qt.UserRole) or '').strip()
        if key == 'reply':
            self.input.setFocus(QtCore.Qt.OtherFocusReason)
            self._open_chat_keyboard()
            return
        if key == 'friend_request':
            self._send_friend_request()
            return
        if key == 'friend_requests':
            self._open_friend_requests()
            return
        if key == 'friends':
            self._show_friends()
            return
        if key == 'voice_call_hub':
            self._open_voice_call_hub()
            return
        if key == 'add_peer':
            self._add_peer()
            return
        if key == 'peer_ids':
            self._show_peer_ids()
            return
        if key == 'lan_status':
            self._show_lan_status()
            return
        if key == 'world_toggle':
            self._toggle_world_chat()
            return
        if key == 'world_room':
            self._change_world_room()
            return

    def _update_peer_meta(self):
        peer = self._selected_peer()
        if not peer:
            self.peer_meta.setText('Select a peer to chat.')
            return
        if str(peer.get('source')) == 'WORLD':
            self.peer_meta.setText(f"WORLD relay room #{self.engine.world_topic}")
            return
        name = str(peer.get('name') or 'Peer')
        host = str(peer.get('host') or '-')
        port = int(peer.get('port') or 0)
        src = str(peer.get('source') or 'LAN')
        self.peer_meta.setText(f'{name}  [{host}:{port}]  ({src})')

    def _open_chat_keyboard(self):
        if self._vk_opening:
            return
        if (time.monotonic() - float(self._vk_last_close)) < 0.35:
            return
        self._vk_opening = True
        try:
            d = VirtualKeyboardDialog(self.input.text(), self)
            if d.exec_() == QtWidgets.QDialog.Accepted:
                self.input.setText(d.text())
        finally:
            self._vk_last_close = time.monotonic()
            self._vk_opening = False
            self.input.setFocus(QtCore.Qt.OtherFocusReason)

    def eventFilter(self, obj, event):
        if obj is self.input:
            et = event.type()
            if et in (QtCore.QEvent.FocusIn, QtCore.QEvent.MouseButtonPress):
                if not self._vk_opening and (time.monotonic() - float(self._vk_last_close)) >= 0.35:
                    QtCore.QTimer.singleShot(0, self._open_chat_keyboard)
        return super().eventFilter(obj, event)

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
        self._push_recent_message(who, text)

    def _push_recent_message(self, who, text):
        who_txt = str(who or '').strip() or 'Unknown'
        body = str(text or '').strip()
        if not body:
            return
        arr = safe_json_read(SOCIAL_MESSAGES_FILE, [])
        if not isinstance(arr, list):
            arr = []
        arr.insert(0, {'ts': int(time.time()), 'from': who_txt[:48], 'text': body[:320]})
        safe_json_write(SOCIAL_MESSAGES_FILE, arr[:80])

    def _friend_endpoint_key(self, host, port):
        h = str(host or '').strip().lower()
        try:
            p = int(port or 0)
        except Exception:
            p = 0
        return f'{h}:{p}'

    def _load_friends(self):
        arr = safe_json_read(FRIENDS_FILE, [])
        if not isinstance(arr, list):
            arr = []
        out = []
        for raw in arr:
            if not isinstance(raw, dict):
                continue
            name = str(raw.get('name') or '').strip()
            host = str(raw.get('host') or '').strip()
            try:
                port = int(raw.get('port') or 0)
            except Exception:
                port = 0
            out.append({
                'name': name or host or 'Friend',
                'host': host,
                'port': int(port),
                'online': bool(raw.get('online', False)),
                'accepted': bool(raw.get('accepted', True)),
                'last_seen': int(raw.get('last_seen', int(time.time()))),
            })
        self.friends = out

    def _save_friends(self):
        safe_json_write(FRIENDS_FILE, self.friends)

    def _friend_matches_peer(self, friend, peer):
        fh = str(friend.get('host') or '').strip().lower()
        ph = str(peer.get('host') or '').strip().lower()
        fp = int(friend.get('port') or 0)
        pp = int(peer.get('port') or 0)
        if fh and ph and fh == ph and fp > 0 and pp > 0 and fp == pp:
            return True
        fn = str(friend.get('name') or '').strip().lower()
        pn = str(peer.get('name') or '').strip().lower()
        return bool(fn and pn and fn == pn)

    def _is_friend(self, peer):
        for f in self.friends:
            if self._friend_matches_peer(f, peer):
                return True
        return False

    def _mark_friend_online(self, peer, online=True):
        changed = False
        now = int(time.time())
        for f in self.friends:
            if self._friend_matches_peer(f, peer):
                if f.get('online') != bool(online):
                    f['online'] = bool(online)
                    changed = True
                f['last_seen'] = now
                changed = True
        if changed:
            self._save_friends()

    def _upsert_friend(self, name, host, port):
        host = str(host or '').strip()
        try:
            port = int(port or 0)
        except Exception:
            port = 0
        key = self._friend_endpoint_key(host, port)
        now = int(time.time())
        for f in self.friends:
            if self._friend_endpoint_key(f.get('host'), f.get('port')) == key:
                f['name'] = str(name or f.get('name') or host or 'Friend')
                f['online'] = True
                f['accepted'] = True
                f['last_seen'] = now
                self._save_friends()
                return
        self.friends.append({
            'name': str(name or host or 'Friend'),
            'host': host,
            'port': int(port),
            'online': True,
            'accepted': True,
            'last_seen': now,
        })
        self._save_friends()

    def _load_friend_requests(self):
        arr = safe_json_read(FRIEND_REQUESTS_FILE, [])
        if not isinstance(arr, list):
            arr = []
        out = []
        for raw in arr:
            if not isinstance(raw, dict):
                continue
            out.append({
                'name': str(raw.get('name') or 'Unknown').strip() or 'Unknown',
                'host': str(raw.get('host') or '').strip(),
                'port': int(raw.get('port') or 0),
                'note': str(raw.get('note') or '').strip(),
                'ts': int(raw.get('ts') or int(time.time())),
            })
        self.friend_requests = out

    def _save_friend_requests(self):
        safe_json_write(FRIEND_REQUESTS_FILE, self.friend_requests)

    def _queue_friend_request(self, name, host, port, note=''):
        key = self._friend_endpoint_key(host, port)
        for req in self.friend_requests:
            if self._friend_endpoint_key(req.get('host'), req.get('port')) == key:
                req['name'] = str(name or req.get('name') or 'Unknown')
                req['note'] = str(note or req.get('note') or '')
                req['ts'] = int(time.time())
                self._save_friend_requests()
                return
        self.friend_requests.insert(0, {
            'name': str(name or 'Unknown'),
            'host': str(host or ''),
            'port': int(port or 0),
            'note': str(note or ''),
            'ts': int(time.time()),
        })
        self.friend_requests = self.friend_requests[:120]
        self._save_friend_requests()

    def _show_friends(self):
        if not self.friends:
            QtWidgets.QMessageBox.information(self, 'Friends', 'No friends yet.')
            return
        lines = []
        for i, f in enumerate(self.friends, 1):
            name = str(f.get('name') or 'Friend')
            host = str(f.get('host') or '-')
            port = int(f.get('port') or 0)
            online = 'Online' if bool(f.get('online')) else 'Offline'
            endpoint = f'{host}:{port}' if host and port > 0 else host
            lines.append(f'{i}. {name} - {online} - {endpoint}')
        QtWidgets.QMessageBox.information(self, 'Friends', '\n'.join(lines))

    def _send_friend_request(self):
        peer = self._selected_peer()
        if not peer or str(peer.get('source')) == 'WORLD':
            QtWidgets.QMessageBox.information(self, 'Friend Request', 'Select a LAN/P2P peer first.')
            return
        candidates = self._send_candidates(peer)
        err = None
        sent = None
        for host, port, _key in candidates:
            try:
                self.engine.send_friend_request(host, port, f'Add {self.nickname} as friend')
                sent = (host, int(port))
                break
            except Exception as exc:
                err = exc
        if sent:
            self.status.setText(f'Friend request sent to {sent[0]}:{sent[1]}')
            self._append_system(f"Friend request sent to {peer.get('name', 'peer')}")
            return
        self.status.setText(f'Friend request failed: {err or "unreachable peer"}')

    def _open_friend_requests(self):
        if not self.friend_requests:
            QtWidgets.QMessageBox.information(self, 'Friend Requests', 'No pending requests.')
            return
        lines = []
        for i, req in enumerate(self.friend_requests[:40], 1):
            note = str(req.get('note') or '').strip()
            suffix = f' | {note}' if note else ''
            lines.append(
                f"{i}. {req.get('name','Unknown')} [{req.get('host','-')}:{int(req.get('port') or 0)}]{suffix}"
            )
        idx, ok = QtWidgets.QInputDialog.getInt(
            self,
            'Friend Requests',
            'Select request number to accept/reject:\n\n' + '\n'.join(lines),
            1,
            1,
            len(self.friend_requests),
            1,
        )
        if not ok:
            return
        req = self.friend_requests[int(idx) - 1]
        ans = QtWidgets.QMessageBox.question(
            self,
            'Friend Request',
            f"Accept friend request from {req.get('name','Unknown')}?",
            QtWidgets.QMessageBox.Yes | QtWidgets.QMessageBox.No | QtWidgets.QMessageBox.Cancel,
            QtWidgets.QMessageBox.Yes,
        )
        if ans == QtWidgets.QMessageBox.Cancel:
            return
        if ans == QtWidgets.QMessageBox.Yes:
            self._upsert_friend(req.get('name'), req.get('host'), req.get('port'))
            self._append_system(f"Friend added: {req.get('name', 'Unknown')}")
            self.status.setText(f"Friend added: {req.get('name', 'Unknown')}")
        else:
            self._append_system(f"Friend request rejected: {req.get('name', 'Unknown')}")
        self.friend_requests.pop(int(idx) - 1)
        self._save_friend_requests()

    def _peer_row(self, peer):
        if str(peer.get('source')) == 'WORLD':
            return f"{peer['name']}  [global relay]  (WORLD)"
        return f"{peer['name']}  [{peer['host']}:{peer['port']}]  ({peer['source']})"

    def _upsert_peer(self, peer, persist=False):
        key = f"{peer['host']}:{int(peer.get('port', 0) or 0)}:{peer.get('source', '')}"
        data = {
            'name': str(peer.get('name') or peer.get('host')),
            'host': str(peer.get('host')),
            'port': int(peer.get('port') or 0),
            'source': str(peer.get('source') or 'LAN'),
            'node_id': str(peer.get('node_id') or ''),
            '_world': bool(peer.get('_world', False)),
        }
        if not data['host']:
            return
        if data['source'] != 'WORLD' and data['port'] <= 0:
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
        self._update_peer_meta()
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
        self._update_peer_meta()

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
            if str(p.get('source') or '') == 'WORLD':
                continue
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

    def _open_voice_call_hub(self):
        script = XUI_HOME / 'bin' / 'xui_social_chat.py'
        if not script.exists():
            self.status.setText(f'Voice/Call hub missing: {script}')
            return
        try:
            subprocess.Popen(
                ['/bin/sh', '-c', f'"{script}"'],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self.status.setText('Opened Voice/Call hub.')
            self._append_system('Opened global Voice/Call hub.')
        except Exception as exc:
            self.status.setText(f'Cannot open Voice/Call hub: {exc}')

    def _load_world_settings(self):
        cfg = safe_json_read(WORLD_CHAT_FILE, {})
        room = str(cfg.get('room', '')).strip()
        enabled = bool(cfg.get('enabled', True))
        if room:
            self.engine.set_world_topic(room)
        self.engine.set_world_enabled(enabled)
        self._update_world_toggle_button()

    def _save_world_settings(self):
        safe_json_write(
            WORLD_CHAT_FILE,
            {
                'room': self.engine.world_topic,
                'enabled': bool(self.engine.world_enabled),
                'relay': self.engine.world_relay,
            },
        )

    def _world_peer_payload(self):
        return {
            'name': f"WORLD #{self.engine.world_topic}",
            'host': self.engine.world_relay,
            'port': 0,
            'source': 'WORLD',
            'node_id': f'world:{self.engine.world_topic}',
            '_world': True,
        }

    def _refresh_world_peer(self):
        existing = None
        for key, p in list(self.peer_data.items()):
            if str(p.get('source')) == 'WORLD' or bool(p.get('_world')):
                existing = key
                break
        if existing is not None:
            self._remove_peer(existing)
        if self.engine.world_enabled:
            self._upsert_peer(self._world_peer_payload(), persist=False)
        self._update_world_toggle_button()

    def _update_world_toggle_button(self):
        it = self._action_items.get('world_toggle')
        if it is None:
            return
        if self.engine.world_enabled:
            it.setText('World Chat: ON')
        else:
            it.setText('World Chat: OFF')

    def _toggle_world_chat(self):
        self.engine.set_world_enabled(not self.engine.world_enabled)
        self._refresh_world_peer()
        self._save_world_settings()

    def _change_world_room(self):
        d = EscInputDialog(self)
        d.setWindowTitle('World Chat Room')
        d.setLabelText('Room/topic name (letters, numbers, -, _, .)')
        d.setInputMode(QtWidgets.QInputDialog.TextInput)
        d.setTextValue(self.engine.world_topic)
        if d.exec_() != QtWidgets.QDialog.Accepted:
            return
        raw = d.textValue()
        self.engine.set_world_topic(raw)
        self._refresh_world_peer()
        self._save_world_settings()
        self._append_system(f'World room changed to: {self.engine.world_topic}')

    def _send_current(self):
        peer = self._selected_peer()
        if not peer:
            QtWidgets.QMessageBox.information(self, 'Peer required', 'Select a peer first.')
            return
        txt = self.input.text().strip()
        if not txt:
            return
        if str(peer.get('source')) == 'WORLD':
            try:
                self.engine.send_world_chat(txt)
                self._append_line(f"[{time.strftime('%H:%M:%S')}] You -> WORLD: {txt}")
                self._push_recent_message('You -> WORLD', txt)
                self.status.setText(f"World sent to room {self.engine.world_topic}")
                self.input.clear()
            except Exception as e:
                self.status.setText(f'World send failed: {e}')
            return
        is_friend = self._is_friend(peer)
        last_err = None
        used = None
        candidates = self._send_candidates(peer)
        for host, port, key in candidates:
            try:
                if is_friend:
                    self.engine.send_private_message(host, port, txt)
                else:
                    self.engine.send_chat(host, port, txt)
                used = (host, int(port), key)
                break
            except Exception as e:
                last_err = e
                continue
        if used:
            host, port, key = used
            if is_friend:
                self._append_line(f"[{time.strftime('%H:%M:%S')}] You -> {peer['name']} [PM]: {txt}")
                self._push_recent_message(f"You -> {peer['name']} [PM]", txt)
            else:
                self._append_chat(f"You -> {peer['name']}", txt)
            if host == str(peer.get('host')) and int(port) == int(peer.get('port') or 0):
                mode = 'PM' if is_friend else 'Chat'
                self.status.setText(f"{mode} sent to {host}:{port}")
            else:
                mode = 'PM' if is_friend else 'Chat'
                self.status.setText(f"{mode} sent via fallback {host}:{port}")
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
                self._mark_friend_online(data, True)
            elif kind == 'peer_down':
                _kind, key = evt
                peer = self.peer_data.get(key)
                if peer and peer.get('source') == 'LAN':
                    self._mark_friend_online(peer, False)
                    self._remove_peer(key)
            elif kind == 'chat':
                _kind, sender, text = evt
                self._append_chat(sender, text)
            elif kind == 'private_message':
                _kind, sender, text = evt
                self._append_line(f"[{time.strftime('%H:%M:%S')}] {sender} [PM]: {text}")
                self._push_recent_message(f'{sender} [PM]', text)
            elif kind == 'friend_request':
                _kind, sender, host, port, note = evt
                self._queue_friend_request(sender, host, port, note)
                self._append_system(f"Friend request from {sender} [{host}:{port}]")
                self.status.setText(f"Pending friend requests: {len(self.friend_requests)}")
            elif kind == 'world_chat':
                _kind, sender, text = evt
                self._append_line(f"[{time.strftime('%H:%M:%S')}] {sender} [WORLD]: {text}")
                self._push_recent_message(f'{sender} [WORLD]', text)
            elif kind == 'world_status':
                _kind, enabled, room = evt
                self._update_world_toggle_button()
                if bool(enabled):
                    self.status.setText(f'World chat connected ({room})')
                else:
                    self.status.setText('World chat disconnected')
                self._refresh_world_peer()
            elif kind == 'world_room':
                _kind, room = evt
                self._refresh_world_peer()
                self.status.setText(f'World room: {room}')

    def closeEvent(self, e):
        try:
            self.timer.stop()
        except Exception:
            pass
        self._stop_call_session(notify=False)
        self._save_world_settings()
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
        self._scale = 1.0
        self._compact = False
        h = QtWidgets.QHBoxLayout(self)
        self._layout = h
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(28)
        for i, n in enumerate(self.names):
            lbl = TabLabel(n)
            lbl.setCursor(QtGui.QCursor(QtCore.Qt.PointingHandCursor))
            lbl.clicked.connect(lambda i=i: self.changed.emit(i))
            self.labels.append(lbl)
            h.addWidget(lbl)
        h.addStretch(1)
        self.apply_scale(1.0, False)
        self.set_current(0)

    def apply_scale(self, scale=1.0, compact=False):
        self._scale = max(0.62, float(scale))
        self._compact = bool(compact)
        spacing = int(28 * self._scale * (0.75 if self._compact else 1.0))
        self._layout.setSpacing(max(8, spacing))
        self.set_current(self.current)

    def set_current(self, idx):
        self.current = max(0, min(idx, len(self.labels)-1))
        active_px = max(22, int((56 if not self._compact else 36) * self._scale))
        idle_px = max(18, int((48 if not self._compact else 30) * self._scale))
        for i, lbl in enumerate(self.labels):
            if i == self.current:
                lbl.setStyleSheet(f'color:#f3f7f7; font-size:{active_px}px; font-weight:700;')
            else:
                lbl.setStyleSheet(f'color:rgba(243,247,247,0.78); font-size:{idle_px}px; font-weight:600;')


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

    def __init__(self, action, text, size=(250, 140), parent=None, icon_scale=1.0, text_scale=1.0, dense=False):
        super().__init__(parent)
        self.action = action
        self.text = text
        self.base_size = (int(size[0]), int(size[1]))
        self.icon_scale = max(0.55, float(icon_scale))
        self.text_scale = max(0.65, float(text_scale))
        self.dense = bool(dense)
        self.setObjectName('green_tile')
        self.setFocusPolicy(QtCore.Qt.StrongFocus)
        v = QtWidgets.QVBoxLayout(self)
        self._layout = v
        v.setContentsMargins(16, 12, 16, 12)
        top = QtWidgets.QHBoxLayout()
        self._top_layout = top
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
        self.apply_scale(1.0, False)
        self.set_selected(False)

    def apply_scale(self, scale=1.0, compact=False):
        s = max(0.62, float(scale))
        compact_factor = 0.85 if compact else 1.0
        if self.dense:
            compact_factor *= 0.92
        w = max(170, int(self.base_size[0] * s * compact_factor))
        h = max(90, int(self.base_size[1] * s * compact_factor))
        self.setFixedSize(w, h)
        pad_x = max(7, int((13 if self.dense else 16) * s * compact_factor))
        pad_y = max(5, int((8 if self.dense else 12) * s * compact_factor))
        self._layout.setContentsMargins(pad_x, pad_y, pad_x, pad_y)
        icon_sz = max(22, int(44 * s * compact_factor * self.icon_scale))
        pix_sz = max(14, int(26 * s * compact_factor * self.icon_scale))
        self.icon.setFixedSize(icon_sz, icon_sz)
        icon = tile_icon(self.action, self.text)
        self.icon.setPixmap(icon.pixmap(pix_sz, pix_sz))
        font_px = max(13, int(30 * s * compact_factor * self.text_scale))
        self.lbl.setStyleSheet(f'color:#efffee; font-size:{font_px}px; font-weight:700;')

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
        self.base_size = (900, 460)
        self.setObjectName('hero_panel')
        v = QtWidgets.QVBoxLayout(self)
        self._layout = v
        v.setContentsMargins(22, 18, 22, 16)
        self.top_label = QtWidgets.QLabel(self.title)
        self.top_label.setStyleSheet('color:#ecf3f5; font-size:38px; font-weight:700;')
        v.addWidget(self.top_label, 0, alignment=QtCore.Qt.AlignLeft | QtCore.Qt.AlignTop)
        v.addStretch(1)
        self.sub_label = QtWidgets.QLabel(self.subtitle)
        self.sub_label.setStyleSheet('color:rgba(235,242,244,0.78); font-size:24px; font-weight:600;')
        v.addWidget(self.sub_label, 0, alignment=QtCore.Qt.AlignLeft | QtCore.Qt.AlignBottom)
        self.apply_scale(1.0, False)
        self.set_selected(False)

    def apply_scale(self, scale=1.0, compact=False):
        s = max(0.62, float(scale))
        compact_factor = 0.9 if compact else 1.0
        w = max(460, int(self.base_size[0] * s * compact_factor))
        h = max(250, int(self.base_size[1] * s * compact_factor))
        self.setFixedSize(w, h)
        mx = max(10, int(22 * s * compact_factor))
        my = max(8, int(18 * s * compact_factor))
        mb = max(8, int(16 * s * compact_factor))
        self._layout.setContentsMargins(mx, my, mx, mb)
        title_fs = max(20, int(38 * s * compact_factor))
        sub_fs = max(14, int(24 * s * compact_factor))
        self.top_label.setStyleSheet(f'color:#ecf3f5; font-size:{title_fs}px; font-weight:700;')
        self.sub_label.setStyleSheet(f'color:rgba(235,242,244,0.78); font-size:{sub_fs}px; font-weight:600;')

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


class GamesShowcasePanel(QtWidgets.QFrame):
    clicked = QtCore.pyqtSignal(str)

    def __init__(self, action='Games Hub', title='games', subtitle='play now', parent=None):
        super().__init__(parent)
        self.action = action
        self.title = title
        self.subtitle = subtitle
        self.base_size = (900, 460)
        self.setObjectName('games_showcase_panel')
        self.setFocusPolicy(QtCore.Qt.StrongFocus)
        self._cards = []
        self._build()
        self.apply_scale(1.0, False)
        self.set_selected(False)

    def _make_mini_card(self, label):
        card = QtWidgets.QFrame()
        card.setObjectName('games_mini_card')
        card_l = QtWidgets.QVBoxLayout(card)
        card_l.setContentsMargins(8, 6, 8, 6)
        card_l.setSpacing(0)
        cat = QtWidgets.QLabel('GAME')
        cat.setObjectName('games_mini_cat')
        name = QtWidgets.QLabel(label)
        name.setObjectName('games_mini_name')
        card_l.addWidget(cat, 0, QtCore.Qt.AlignLeft | QtCore.Qt.AlignTop)
        card_l.addStretch(1)
        card_l.addWidget(name, 0, QtCore.Qt.AlignLeft | QtCore.Qt.AlignBottom)
        return card

    def _build(self):
        root = QtWidgets.QVBoxLayout(self)
        self._layout = root
        root.setContentsMargins(18, 16, 18, 12)
        root.setSpacing(8)

        title_row = QtWidgets.QHBoxLayout()
        self.top_label = QtWidgets.QLabel(self.title)
        self.top_label.setObjectName('games_title')
        title_row.addWidget(self.top_label, 0, QtCore.Qt.AlignLeft)
        title_row.addStretch(1)
        root.addLayout(title_row)

        body = QtWidgets.QHBoxLayout()
        body.setSpacing(10)

        blades = QtWidgets.QFrame()
        blades.setObjectName('games_blades')
        blades_l = QtWidgets.QVBoxLayout(blades)
        blades_l.setContentsMargins(6, 6, 6, 6)
        blades_l.setSpacing(4)
        self.btn_my_games = QtWidgets.QPushButton('My Games')
        self.btn_browse_games = QtWidgets.QPushButton('Browse Games')
        self.btn_search_games = QtWidgets.QPushButton('Search Games')
        for b in (self.btn_my_games, self.btn_browse_games, self.btn_search_games):
            b.setObjectName('games_blade_btn')
            blades_l.addWidget(b)
        blades_l.addStretch(1)
        self.btn_my_games.clicked.connect(lambda: self.clicked.emit('My Games'))
        self.btn_browse_games.clicked.connect(lambda: self.clicked.emit('Browse Games'))
        self.btn_search_games.clicked.connect(lambda: self.clicked.emit('Search Games'))
        body.addWidget(blades, 1)

        right = QtWidgets.QVBoxLayout()
        right.setSpacing(8)

        covers = QtWidgets.QHBoxLayout()
        covers.setSpacing(8)
        self.featured = QtWidgets.QFrame()
        self.featured.setObjectName('games_featured')
        ft_l = QtWidgets.QVBoxLayout(self.featured)
        ft_l.setContentsMargins(10, 8, 10, 8)
        ft_l.setSpacing(2)
        self.featured_tag = QtWidgets.QLabel('HIGHLIGHT')
        self.featured_tag.setObjectName('games_featured_tag')
        self.featured_name = QtWidgets.QLabel('Halo 4')
        self.featured_name.setObjectName('games_featured_name')
        self.featured_sub = QtWidgets.QLabel('Open your collection and continue playing')
        self.featured_sub.setObjectName('games_featured_sub')
        ft_l.addWidget(self.featured_tag, 0, QtCore.Qt.AlignLeft)
        ft_l.addStretch(1)
        ft_l.addWidget(self.featured_name, 0, QtCore.Qt.AlignLeft)
        ft_l.addWidget(self.featured_sub, 0, QtCore.Qt.AlignLeft)
        covers.addWidget(self.featured, 2)

        mini_col = QtWidgets.QVBoxLayout()
        mini_col.setSpacing(8)
        for label in ('Forza 4', 'Gears', 'FIFA', 'MW3'):
            card = self._make_mini_card(label)
            self._cards.append(card)
            mini_col.addWidget(card, 1)
        covers.addLayout(mini_col, 1)
        right.addLayout(covers, 1)

        rec = QtWidgets.QFrame()
        rec.setObjectName('games_recommend')
        rec_l = QtWidgets.QVBoxLayout(rec)
        rec_l.setContentsMargins(10, 6, 10, 6)
        rec_l.setSpacing(2)
        rec_tag = QtWidgets.QLabel('RECOMMENDATIONS')
        rec_tag.setObjectName('games_recommend_tag')
        rec_text = QtWidgets.QLabel('Popular now: Runner, Gem Match, FNAE')
        rec_text.setObjectName('games_recommend_text')
        rec_l.addWidget(rec_tag, 0, QtCore.Qt.AlignLeft)
        rec_l.addWidget(rec_text, 0, QtCore.Qt.AlignLeft)
        right.addWidget(rec, 0)

        body.addLayout(right, 4)

        root.addLayout(body, 1)
        self.sub_label = QtWidgets.QLabel(self.subtitle)
        self.sub_label.setObjectName('games_sub')
        root.addWidget(self.sub_label, 0, QtCore.Qt.AlignLeft | QtCore.Qt.AlignBottom)

    def apply_scale(self, scale=1.0, compact=False):
        s = max(0.62, float(scale))
        compact_factor = 0.88 if compact else 1.0
        w = max(480, int(self.base_size[0] * s * compact_factor))
        h = max(260, int(self.base_size[1] * s * compact_factor))
        self.setFixedSize(w, h)

        mx = max(10, int(18 * s * compact_factor))
        my = max(8, int(16 * s * compact_factor))
        self._layout.setContentsMargins(mx, my, mx, max(8, int(12 * s * compact_factor)))
        self._layout.setSpacing(max(6, int(8 * s * compact_factor)))

        title_fs = max(20, int(37 * s * compact_factor))
        sub_fs = max(13, int(22 * s * compact_factor))
        blade_fs = max(11, int(17 * s * compact_factor))
        self.top_label.setStyleSheet(f'color:#f2f6fa; font-size:{title_fs}px; font-weight:800;')
        self.sub_label.setStyleSheet(f'color:rgba(235,242,244,0.78); font-size:{sub_fs}px; font-weight:600;')

        blade_h = max(40, int(58 * s * compact_factor))
        for b in (self.btn_my_games, self.btn_browse_games, self.btn_search_games):
            b.setMinimumHeight(blade_h)
            b.setStyleSheet(
                'QPushButton#games_blade_btn {'
                'text-align:left; padding:6px 8px;'
                f'font-size:{blade_fs}px; font-weight:700;'
                'color:#ecf4ef; background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #57b541, stop:1 #3b8f31);'
                'border:1px solid rgba(255,255,255,0.24); border-radius:2px; }'
                'QPushButton#games_blade_btn:hover { background:#65c44d; }'
            )

        feat_name_fs = max(14, int(31 * s * compact_factor))
        feat_sub_fs = max(10, int(16 * s * compact_factor))
        self.featured_tag.setStyleSheet(f'color:rgba(220,231,236,0.92); font-size:{max(9, int(12 * s))}px; font-weight:700;')
        self.featured_name.setStyleSheet(f'color:#eff4f8; font-size:{feat_name_fs}px; font-weight:800;')
        self.featured_sub.setStyleSheet(f'color:rgba(234,241,246,0.86); font-size:{feat_sub_fs}px; font-weight:600;')

        mini_h = max(54, int(88 * s * compact_factor))
        mini_cat_fs = max(8, int(11 * s * compact_factor))
        mini_name_fs = max(10, int(17 * s * compact_factor))
        for c in self._cards:
            c.setMinimumHeight(mini_h)
            c.setStyleSheet(
                'QFrame#games_mini_card {'
                'background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #707b84, stop:1 #4f5962);'
                'border:1px solid rgba(223,232,239,0.5); border-radius:2px; }'
                f'QLabel#games_mini_cat {{ color:rgba(229,236,241,0.82); font-size:{mini_cat_fs}px; font-weight:700; }}'
                f'QLabel#games_mini_name {{ color:#f3f7f9; font-size:{mini_name_fs}px; font-weight:700; }}'
            )

    def set_selected(self, on):
        border = '#d4f2ff' if on else 'rgba(255,255,255,0.08)'
        width = '4px' if on else '1px'
        self.setStyleSheet(
            f'''
            QFrame#games_showcase_panel {{
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #121518, stop:1 #1f262c);
                border:{width} solid {border};
                border-radius:4px;
            }}
            QFrame#games_blades {{
                background:rgba(18,24,30,0.92);
                border:1px solid rgba(194,213,231,0.3);
            }}
            QFrame#games_featured {{
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #4f5962, stop:1 #3b444d);
                border:1px solid rgba(223,232,239,0.5);
                border-radius:2px;
            }}
            QFrame#games_recommend {{
                background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #d8dde3, stop:1 #c8ced5);
                border:1px solid rgba(117,126,136,0.5);
                border-radius:2px;
            }}
            QLabel#games_recommend_tag {{
                color:#3f4a56;
                font-size:11px;
                font-weight:800;
            }}
            QLabel#games_recommend_text {{
                color:#2f3944;
                font-size:14px;
                font-weight:700;
            }}
            '''
        )

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
        self._open_anim = None
        self.descriptions = descriptions or {}
        self.resize(760, 500)
        self.setStyleSheet('''
            QFrame#guide_panel {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #d9dde2, stop:1 #9ca3aa);
                border:2px solid rgba(226,236,246,0.72);
                border-radius:5px;
            }
            QLabel#guide_title { color:#1f252b; font-size:34px; font-weight:800; }
            QLabel#guide_hint { color:rgba(22,27,33,0.82); font-size:16px; font-weight:600; }
            QFrame#guide_left {
                background:rgba(246,248,250,0.86);
                border:1px solid rgba(132,142,152,0.54);
            }
            QFrame#guide_info {
                background:rgba(74,80,88,0.78);
                border:1px solid rgba(223,229,236,0.54);
            }
            QLabel#guide_info_title {
                color:#eff4f7;
                font-size:19px;
                font-weight:700;
            }
            QLabel#guide_info_text {
                color:rgba(237,243,247,0.94);
                font-size:15px;
            }
            QListWidget {
                background:#f6f7f8;
                color:#20262d;
                font-size:27px;
                border:1px solid #8e979f;
                outline:none;
            }
            QListWidget::item {
                padding:7px 10px;
                border:1px solid transparent;
                margin:1px 0px;
            }
            QListWidget::item:selected {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #5abc3e, stop:1 #3d8f31);
                color:#f4fff2;
                border:1px solid rgba(248,255,247,0.36);
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
        self._animate_open()

    def _animate_open(self):
        effect = QtWidgets.QGraphicsOpacityEffect(self)
        self.setGraphicsEffect(effect)
        effect.setOpacity(0.0)
        end_rect = self.geometry()
        start_rect = QtCore.QRect(end_rect.x(), end_rect.y() + max(18, end_rect.height() // 22), end_rect.width(), end_rect.height())
        self.setGeometry(start_rect)
        self._open_anim = QtCore.QParallelAnimationGroup(self)
        fade = QtCore.QPropertyAnimation(effect, b'opacity', self)
        fade.setDuration(180)
        fade.setStartValue(0.0)
        fade.setEndValue(1.0)
        fade.setEasingCurve(QtCore.QEasingCurve.OutCubic)
        slide = QtCore.QPropertyAnimation(self, b'geometry', self)
        slide.setDuration(220)
        slide.setStartValue(start_rect)
        slide.setEndValue(end_rect)
        slide.setEasingCurve(QtCore.QEasingCurve.OutCubic)
        self._open_anim.addAnimation(fade)
        self._open_anim.addAnimation(slide)
        self._open_anim.finished.connect(lambda: self.setGraphicsEffect(None))
        self._open_anim.start(QtCore.QAbstractAnimation.DeleteWhenStopped)

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


class GamesHubMenu(QtWidgets.QDialog):
    def __init__(self, items, parent=None):
        super().__init__(parent)
        self._items = list(items or [])
        self._selection = None
        self._open_anim = None
        self.setWindowTitle('games hub')
        self.setWindowFlags(QtCore.Qt.Dialog | QtCore.Qt.FramelessWindowHint)
        self.setAttribute(QtCore.Qt.WA_TranslucentBackground, True)
        self.setModal(True)
        self.resize(980, 560)
        self.setStyleSheet('''
            QFrame#games_hub_panel {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #d7dce2, stop:1 #a2a9b1);
                border:2px solid rgba(226,236,246,0.72);
                border-radius:6px;
            }
            QLabel#games_hub_title {
                color:#28313b;
                font-size:36px;
                font-weight:800;
            }
            QLabel#games_hub_hint {
                color:rgba(23,29,35,0.85);
                font-size:15px;
                font-weight:600;
            }
            QFrame#games_hub_list_box {
                background:rgba(248,250,252,0.9);
                border:1px solid rgba(133,143,154,0.56);
            }
            QListWidget#games_hub_list {
                background:transparent;
                color:#212830;
                font-size:30px;
                border:none;
                outline:none;
            }
            QListWidget#games_hub_list::item {
                padding:7px 10px;
                margin:1px 0px;
            }
            QListWidget#games_hub_list::item:selected {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #5cbc42, stop:1 #3c8f31);
                color:#f4fff2;
                border:1px solid rgba(248,255,247,0.36);
            }
            QFrame#games_hub_preview {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #4f5963, stop:1 #3f4751);
                border:1px solid rgba(226,235,243,0.58);
            }
            QLabel#games_hub_preview_tag {
                color:rgba(228,237,244,0.86);
                font-size:12px;
                font-weight:700;
                letter-spacing:1px;
            }
            QLabel#games_hub_preview_title {
                color:#f2f6fa;
                font-size:32px;
                font-weight:800;
            }
            QLabel#games_hub_preview_desc {
                color:rgba(234,241,246,0.92);
                font-size:16px;
                font-weight:600;
            }
            QFrame#games_hub_card {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #747f88, stop:1 #515a63);
                border:1px solid rgba(226,235,243,0.55);
                border-radius:2px;
            }
            QLabel#games_hub_card_title {
                color:#f4f8fb;
                font-size:14px;
                font-weight:700;
            }
        ''')
        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        panel = QtWidgets.QFrame()
        panel.setObjectName('games_hub_panel')
        outer.addWidget(panel)

        root = QtWidgets.QVBoxLayout(panel)
        root.setContentsMargins(12, 10, 12, 10)
        root.setSpacing(8)

        top = QtWidgets.QHBoxLayout()
        title = QtWidgets.QLabel('games hub')
        title.setObjectName('games_hub_title')
        top.addWidget(title, 0, QtCore.Qt.AlignLeft)
        top.addStretch(1)
        root.addLayout(top)

        body = QtWidgets.QHBoxLayout()
        body.setSpacing(10)

        left = QtWidgets.QFrame()
        left.setObjectName('games_hub_list_box')
        left_l = QtWidgets.QVBoxLayout(left)
        left_l.setContentsMargins(8, 8, 8, 8)
        left_l.setSpacing(6)
        self.listw = QtWidgets.QListWidget()
        self.listw.setObjectName('games_hub_list')
        self.listw.addItems([str(x.get('label', 'Option')) for x in self._items])
        self.listw.setCurrentRow(0 if self._items else -1)
        self.listw.itemActivated.connect(self._accept_current)
        self.listw.itemDoubleClicked.connect(self._accept_current)
        left_l.addWidget(self.listw, 1)
        body.addWidget(left, 2)

        right_wrap = QtWidgets.QVBoxLayout()
        right_wrap.setSpacing(8)
        preview = QtWidgets.QFrame()
        preview.setObjectName('games_hub_preview')
        preview_l = QtWidgets.QVBoxLayout(preview)
        preview_l.setContentsMargins(12, 10, 12, 10)
        preview_l.setSpacing(4)
        self.preview_tag = QtWidgets.QLabel('FEATURED')
        self.preview_tag.setObjectName('games_hub_preview_tag')
        self.preview_title = QtWidgets.QLabel('My Games')
        self.preview_title.setObjectName('games_hub_preview_title')
        self.preview_desc = QtWidgets.QLabel('')
        self.preview_desc.setWordWrap(True)
        self.preview_desc.setObjectName('games_hub_preview_desc')
        preview_l.addWidget(self.preview_tag, 0, QtCore.Qt.AlignLeft)
        preview_l.addStretch(1)
        preview_l.addWidget(self.preview_title, 0, QtCore.Qt.AlignLeft)
        preview_l.addWidget(self.preview_desc, 0, QtCore.Qt.AlignLeft)
        right_wrap.addWidget(preview, 1)

        card_row = QtWidgets.QHBoxLayout()
        card_row.setSpacing(8)
        self.preview_cards = []
        for _ in range(4):
            c = QtWidgets.QFrame()
            c.setObjectName('games_hub_card')
            c_l = QtWidgets.QVBoxLayout(c)
            c_l.setContentsMargins(8, 8, 8, 8)
            c_l.setSpacing(0)
            lbl = QtWidgets.QLabel('game')
            lbl.setObjectName('games_hub_card_title')
            c_l.addStretch(1)
            c_l.addWidget(lbl, 0, QtCore.Qt.AlignLeft | QtCore.Qt.AlignBottom)
            self.preview_cards.append(lbl)
            card_row.addWidget(c, 1)
        right_wrap.addLayout(card_row)
        body.addLayout(right_wrap, 4)
        root.addLayout(body, 1)

        hint = QtWidgets.QLabel('ESC = Back | ENTER = Select | Flechas = Move')
        hint.setObjectName('games_hub_hint')
        root.addWidget(hint)

        self.listw.currentRowChanged.connect(self._update_preview)
        self._update_preview(self.listw.currentRow())

    def _item_at(self, row):
        if row < 0 or row >= len(self._items):
            return None
        return self._items[row]

    def _update_preview(self, row):
        item = self._item_at(int(row))
        if not item:
            self.preview_title.setText('games')
            self.preview_desc.setText('')
            for lbl in self.preview_cards:
                lbl.setText('-')
            return
        self.preview_title.setText(str(item.get('label', 'games')))
        self.preview_desc.setText(str(item.get('desc', 'Open this section.')))
        cards = list(item.get('cards', []))
        while len(cards) < len(self.preview_cards):
            cards.append('Classic')
        for i, lbl in enumerate(self.preview_cards):
            lbl.setText(str(cards[i]))

    def selected_action(self):
        if self._selection:
            return self._selection
        row = self.listw.currentRow()
        item = self._item_at(row)
        if not item:
            return None
        return str(item.get('action', ''))

    def _accept_current(self, *_):
        row = self.listw.currentRow()
        item = self._item_at(row)
        if not item:
            return
        self._selection = str(item.get('action', ''))
        self.accept()

    def showEvent(self, e):
        super().showEvent(e)
        parent = self.parentWidget()
        if parent is not None:
            w = min(max(980, int(parent.width() * 0.78)), max(980, parent.width() - 80))
            h = min(max(560, int(parent.height() * 0.74)), max(560, parent.height() - 80))
            self.resize(w, h)
            x = parent.x() + (parent.width() - w) // 2
            y = parent.y() + (parent.height() - h) // 2
            self.move(max(0, x), max(0, y))
        self._animate_open()

    def _animate_open(self):
        effect = QtWidgets.QGraphicsOpacityEffect(self)
        self.setGraphicsEffect(effect)
        effect.setOpacity(0.0)
        end_rect = self.geometry()
        start_rect = QtCore.QRect(end_rect.x() + max(18, end_rect.width() // 26), end_rect.y(), end_rect.width(), end_rect.height())
        self.setGeometry(start_rect)
        self._open_anim = QtCore.QParallelAnimationGroup(self)
        fade = QtCore.QPropertyAnimation(effect, b'opacity', self)
        fade.setDuration(180)
        fade.setStartValue(0.0)
        fade.setEndValue(1.0)
        fade.setEasingCurve(QtCore.QEasingCurve.OutCubic)
        slide = QtCore.QPropertyAnimation(self, b'geometry', self)
        slide.setDuration(220)
        slide.setStartValue(start_rect)
        slide.setEndValue(end_rect)
        slide.setEasingCurve(QtCore.QEasingCurve.OutCubic)
        self._open_anim.addAnimation(fade)
        self._open_anim.addAnimation(slide)
        self._open_anim.finished.connect(lambda: self.setGraphicsEffect(None))
        self._open_anim.start(QtCore.QAbstractAnimation.DeleteWhenStopped)

    def keyPressEvent(self, e):
        if e.key() in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.reject()
            return
        if e.key() in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter):
            self._accept_current()
            return
        super().keyPressEvent(e)


class MandatoryUpdateDialog(QtWidgets.QDialog):
    def __init__(self, payload=None, parent=None):
        super().__init__(parent)
        self.payload = payload if isinstance(payload, dict) else {}
        self._choice = 'No'
        self._open_anim = None
        self.setWindowTitle('Update Required')
        self.setWindowFlags(QtCore.Qt.Dialog | QtCore.Qt.FramelessWindowHint)
        self.setAttribute(QtCore.Qt.WA_TranslucentBackground, True)
        self.setModal(True)
        self.resize(760, 460)
        self.setStyleSheet('''
            QFrame#upd_panel {
                background:#cfd4d9;
                border:2px solid rgba(239,244,248,0.78);
                border-radius:4px;
            }
            QFrame#upd_header {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #69717a, stop:1 #505860);
                border:none;
            }
            QLabel#upd_header_title {
                color:#edf2f6;
                font-size:28px;
                font-weight:800;
            }
            QLabel#upd_body_txt {
                color:#232b33;
                font-size:21px;
                font-weight:600;
            }
            QListWidget#upd_choices {
                background:#e3e7eb;
                color:#1f252c;
                font-size:30px;
                border:1px solid rgba(76,86,96,0.4);
                outline:none;
            }
            QListWidget#upd_choices::item {
                padding:6px 10px;
                margin:1px 0px;
            }
            QListWidget#upd_choices::item:selected {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #5abc3e, stop:1 #3e9132);
                color:#f4fff1;
                border:1px solid rgba(249,255,248,0.4);
            }
            QLabel#upd_hint {
                color:#1f252c;
                font-size:16px;
                font-weight:700;
            }
        ''')
        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        panel = QtWidgets.QFrame()
        panel.setObjectName('upd_panel')
        outer.addWidget(panel)
        root = QtWidgets.QVBoxLayout(panel)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        header = QtWidgets.QFrame()
        header.setObjectName('upd_header')
        h_l = QtWidgets.QHBoxLayout(header)
        h_l.setContentsMargins(12, 8, 12, 8)
        title = QtWidgets.QLabel('Update Required')
        title.setObjectName('upd_header_title')
        h_l.addWidget(title)
        h_l.addStretch(1)
        root.addWidget(header)

        body = QtWidgets.QWidget()
        b_l = QtWidgets.QVBoxLayout(body)
        b_l.setContentsMargins(14, 12, 14, 10)
        b_l.setSpacing(10)
        repo = str(self.payload.get('repo', 'afitler79-alt/XUI-X360-FRONTEND'))
        remote = str(self.payload.get('remote_commit', 'unknown'))[:10]
        txt = (
            'A mandatory system update is available from GitHub.\n'
            'If you decline, you will not be able to continue into the dashboard.\n\n'
            f'Repository: {repo}\n'
            f'Latest build: {remote}\n\n'
            'Do you want to apply the update now?'
        )
        message = QtWidgets.QLabel(txt)
        message.setObjectName('upd_body_txt')
        message.setWordWrap(True)
        b_l.addWidget(message, 1)

        self.choices = QtWidgets.QListWidget()
        self.choices.setObjectName('upd_choices')
        self.choices.addItems(['Yes', 'No'])
        self.choices.setCurrentRow(0)
        self.choices.itemActivated.connect(self._accept_current)
        b_l.addWidget(self.choices, 0)

        hint = QtWidgets.QLabel('A/ENTER = Select | B/ESC = Back')
        hint.setObjectName('upd_hint')
        b_l.addWidget(hint, 0)
        root.addWidget(body, 1)

    def selected_choice(self):
        return str(self._choice or 'No')

    def _accept_current(self, *_):
        it = self.choices.currentItem()
        if it is None:
            self._choice = 'No'
        else:
            self._choice = str(it.text()).strip() or 'No'
        self.accept()

    def showEvent(self, e):
        super().showEvent(e)
        parent = self.parentWidget()
        if parent is not None:
            w = min(max(760, int(parent.width() * 0.54)), max(760, parent.width() - 120))
            h = min(max(440, int(parent.height() * 0.56)), max(440, parent.height() - 120))
            self.resize(w, h)
            x = parent.x() + (parent.width() - w) // 2
            y = parent.y() + (parent.height() - h) // 2
            self.move(max(0, x), max(0, y))
        self._animate_open()

    def _animate_open(self):
        effect = QtWidgets.QGraphicsOpacityEffect(self)
        self.setGraphicsEffect(effect)
        effect.setOpacity(0.0)
        end_rect = self.geometry()
        start_rect = QtCore.QRect(end_rect.x(), end_rect.y() + max(18, end_rect.height() // 20), end_rect.width(), end_rect.height())
        self.setGeometry(start_rect)
        self._open_anim = QtCore.QParallelAnimationGroup(self)
        fade = QtCore.QPropertyAnimation(effect, b'opacity', self)
        fade.setDuration(170)
        fade.setStartValue(0.0)
        fade.setEndValue(1.0)
        fade.setEasingCurve(QtCore.QEasingCurve.OutCubic)
        slide = QtCore.QPropertyAnimation(self, b'geometry', self)
        slide.setDuration(210)
        slide.setStartValue(start_rect)
        slide.setEndValue(end_rect)
        slide.setEasingCurve(QtCore.QEasingCurve.OutCubic)
        self._open_anim.addAnimation(fade)
        self._open_anim.addAnimation(slide)
        self._open_anim.finished.connect(lambda: self.setGraphicsEffect(None))
        self._open_anim.start(QtCore.QAbstractAnimation.DeleteWhenStopped)

    def keyPressEvent(self, e):
        if e.key() in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self._choice = 'No'
            self.reject()
            return
        if e.key() in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter):
            self._accept_current()
            return
        super().keyPressEvent(e)


class UpdateProgressDialog(QtWidgets.QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self._phase = 0
        self.setWindowTitle('Update in Progress')
        self.setWindowFlags(QtCore.Qt.Dialog | QtCore.Qt.FramelessWindowHint)
        self.setModal(True)
        self.resize(760, 360)
        self.setStyleSheet('''
            QDialog {
                background:#e7eaee;
                border:2px solid rgba(242,247,250,0.9);
            }
            QLabel#title {
                color:#f6f8fb;
                background:#151a1f;
                font-size:34px;
                font-weight:800;
                padding:8px 14px;
            }
            QLabel#body {
                color:#27313a;
                font-size:28px;
                font-weight:700;
            }
            QLabel#detail {
                color:#34414e;
                font-size:17px;
                font-weight:700;
            }
            QProgressBar {
                border:1px solid #c9d3db;
                border-radius:2px;
                background:#dfe4e8;
                height:24px;
                text-align:center;
                color:#1e252c;
                font-size:14px;
                font-weight:800;
            }
            QProgressBar::chunk {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #37b935, stop:1 #5dd43f);
            }
        ''')
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(0)
        self.lbl_title = QtWidgets.QLabel('Update in Progress')
        self.lbl_title.setObjectName('title')
        v.addWidget(self.lbl_title)
        body = QtWidgets.QWidget()
        body_l = QtWidgets.QVBoxLayout(body)
        body_l.setContentsMargins(28, 28, 28, 20)
        body_l.setSpacing(18)
        self.lbl = QtWidgets.QLabel('Applying update. Do not turn off or unplug your console.')
        self.lbl.setObjectName('body')
        self.lbl.setWordWrap(True)
        body_l.addStretch(1)
        body_l.addWidget(self.lbl)
        self.bar = QtWidgets.QProgressBar()
        self.bar.setRange(0, 100)
        self.bar.setValue(6)
        self.bar.setFormat('%p%')
        body_l.addWidget(self.bar)
        self.detail = QtWidgets.QLabel('Preparing update...')
        self.detail.setObjectName('detail')
        body_l.addWidget(self.detail)
        body_l.addStretch(1)
        v.addWidget(body, 1)
        self._tick = QtCore.QTimer(self)
        self._tick.timeout.connect(self._pulse)
        self._tick.start(120)

    def _pulse(self):
        cur = self.bar.value()
        target = 92 if self._phase < 1 else 98
        nxt = cur + 1
        if nxt > target:
            nxt = target
        self.bar.setValue(nxt)

    def set_detail(self, text):
        t = str(text or '').strip()
        if t:
            self.detail.setText(t[:220])
        if self.bar.value() < 92:
            self.bar.setValue(min(92, self.bar.value() + 1))

    def finish_ok(self):
        self._phase = 1
        self.bar.setValue(100)
        self.detail.setText('Update installed successfully. Restarting dashboard...')


class InstallTaskProgressDialog(QtWidgets.QDialog):
    def __init__(self, app_title='App', parent=None):
        super().__init__(parent)
        self._phase = 0
        self.setWindowTitle('Install in Progress')
        self.setWindowFlags(QtCore.Qt.Dialog | QtCore.Qt.FramelessWindowHint)
        self.setModal(True)
        self.resize(760, 360)
        self.setStyleSheet('''
            QDialog {
                background:#e7eaee;
                border:2px solid rgba(242,247,250,0.9);
            }
            QLabel#title {
                color:#f6f8fb;
                background:#151a1f;
                font-size:34px;
                font-weight:800;
                padding:8px 14px;
            }
            QLabel#app {
                color:#293645;
                font-size:30px;
                font-weight:800;
            }
            QLabel#body {
                color:#27313a;
                font-size:25px;
                font-weight:700;
            }
            QLabel#detail {
                color:#34414e;
                font-size:17px;
                font-weight:700;
            }
            QProgressBar {
                border:1px solid #c9d3db;
                border-radius:2px;
                background:#dfe4e8;
                height:24px;
                text-align:center;
                color:#1e252c;
                font-size:14px;
                font-weight:800;
            }
            QProgressBar::chunk {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #37b935, stop:1 #5dd43f);
            }
        ''')
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(0)
        self.lbl_title = QtWidgets.QLabel('Install in Progress')
        self.lbl_title.setObjectName('title')
        v.addWidget(self.lbl_title)
        body = QtWidgets.QWidget()
        body_l = QtWidgets.QVBoxLayout(body)
        body_l.setContentsMargins(28, 24, 28, 20)
        body_l.setSpacing(16)
        self.lbl_app = QtWidgets.QLabel(str(app_title or 'App'))
        self.lbl_app.setObjectName('app')
        self.lbl_app.setAlignment(QtCore.Qt.AlignLeft | QtCore.Qt.AlignVCenter)
        body_l.addWidget(self.lbl_app)
        self.lbl = QtWidgets.QLabel('Installing app. Do not turn off or unplug your console.')
        self.lbl.setObjectName('body')
        self.lbl.setWordWrap(True)
        body_l.addWidget(self.lbl)
        self.bar = QtWidgets.QProgressBar()
        self.bar.setRange(0, 100)
        self.bar.setValue(7)
        self.bar.setFormat('%p%')
        body_l.addWidget(self.bar)
        self.detail = QtWidgets.QLabel('Preparing installer...')
        self.detail.setObjectName('detail')
        body_l.addWidget(self.detail)
        body_l.addStretch(1)
        v.addWidget(body, 1)
        self._tick = QtCore.QTimer(self)
        self._tick.timeout.connect(self._pulse)
        self._tick.start(130)

    def _pulse(self):
        cur = self.bar.value()
        target = 93 if self._phase < 1 else 98
        nxt = cur + 1
        if nxt > target:
            nxt = target
        self.bar.setValue(nxt)

    def set_detail(self, text):
        t = str(text or '').strip()
        if t:
            self.detail.setText(t[:220])
        if self.bar.value() < 93:
            self.bar.setValue(min(93, self.bar.value() + 1))

    def finish_ok(self, text='Install completed successfully.'):
        self._phase = 1
        self.bar.setValue(100)
        self.detail.setText(str(text or 'Install completed successfully.'))

    def finish_error(self, text='Install failed.'):
        self._phase = 1
        self.bar.setValue(min(100, max(self.bar.value(), 97)))
        self.detail.setText(str(text or 'Install failed.'))


class XboxGuideMenu(QtWidgets.QDialog):
    def __init__(self, gamertag='Player1', parent=None):
        super().__init__(parent)
        self.gamertag = str(gamertag or 'Player1')
        self._selection = None
        self._open_anim = None
        self.setWindowTitle('Guia Xbox')
        self.setWindowFlags(QtCore.Qt.Dialog | QtCore.Qt.FramelessWindowHint)
        self.setAttribute(QtCore.Qt.WA_TranslucentBackground, True)
        self.setModal(True)
        self.resize(860, 500)
        self.setStyleSheet('''
            QFrame#xguide_panel {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #3a3f46, stop:1 #1e242b);
                border:2px solid rgba(214,223,235,0.52);
                border-radius:7px;
            }
            QLabel#xguide_title {
                color:#eef4f8;
                font-size:28px;
                font-weight:800;
            }
            QLabel#xguide_meta {
                color:rgba(235,242,248,0.78);
                font-size:17px;
                font-weight:600;
            }
            QListWidget#xguide_list {
                background:rgba(236,239,242,0.92);
                color:#20252b;
                border:1px solid rgba(0,0,0,0.26);
                font-size:32px;
                outline:none;
            }
            QListWidget#xguide_list::item {
                padding:6px 10px;
                border:1px solid transparent;
            }
            QListWidget#xguide_list::item:selected {
                color:#f3fff2;
                background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #4ea93f, stop:1 #2f8832);
                border:1px solid rgba(255,255,255,0.25);
            }
            QFrame#xguide_blades {
                background:rgba(65,74,84,0.95);
                border:1px solid rgba(194,206,222,0.25);
            }
            QPushButton#xguide_blade_btn {
                text-align:left;
                padding:8px 10px;
                color:#e9f1f8;
                font-size:20px;
                font-weight:700;
                background:rgba(34,43,54,0.92);
                border:1px solid rgba(186,205,224,0.24);
            }
            QPushButton#xguide_blade_btn:focus,
            QPushButton#xguide_blade_btn:hover {
                background:rgba(58,80,106,0.95);
                border:1px solid rgba(218,233,246,0.52);
            }
            QLabel#xguide_hint {
                color:rgba(238,245,250,0.84);
                font-size:15px;
                font-weight:600;
            }
        ''')
        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        panel = QtWidgets.QFrame()
        panel.setObjectName('xguide_panel')
        outer.addWidget(panel)

        root = QtWidgets.QVBoxLayout(panel)
        root.setContentsMargins(12, 10, 12, 10)
        root.setSpacing(8)

        top = QtWidgets.QHBoxLayout()
        title = QtWidgets.QLabel('Guia Xbox')
        title.setObjectName('xguide_title')
        self.meta = QtWidgets.QLabel('')
        self.meta.setObjectName('xguide_meta')
        top.addWidget(title)
        top.addStretch(1)
        top.addWidget(self.meta)
        root.addLayout(top)

        body = QtWidgets.QHBoxLayout()
        body.setSpacing(10)
        self.listw = QtWidgets.QListWidget()
        self.listw.setObjectName('xguide_list')
        self.listw.addItems([
            'Logros',
            'Premios',
            'Reciente',
            'Mensajes recientes',
            'Social global',
            'Mis juegos',
            'Descargas activas',
            'Canjear codigo',
        ])
        self.listw.setCurrentRow(0)
        self.listw.itemActivated.connect(self._accept_current)
        self.listw.itemDoubleClicked.connect(self._accept_current)
        body.addWidget(self.listw, 4)

        blades = QtWidgets.QFrame()
        blades.setObjectName('xguide_blades')
        blades_l = QtWidgets.QVBoxLayout(blades)
        blades_l.setContentsMargins(8, 8, 8, 8)
        blades_l.setSpacing(6)
        for opt in ('Configuracion', 'Inicio de Xbox', 'Cerrar app actual', 'Cerrar sesion'):
            b = QtWidgets.QPushButton(opt)
            b.setObjectName('xguide_blade_btn')
            b.clicked.connect(lambda _=False, opt=opt: self._accept_action(opt))
            blades_l.addWidget(b)
        blades_l.addStretch(1)
        body.addWidget(blades, 2)
        root.addLayout(body, 1)

        hint = QtWidgets.QLabel('A/ENTER = Select | B/ESC = Back | Xbox Guide = F1 o HOME')
        hint.setObjectName('xguide_hint')
        root.addWidget(hint)

        self._clock = QtCore.QTimer(self)
        self._clock.timeout.connect(self._refresh_meta)
        self._clock.start(1000)
        self._refresh_meta()

    def _refresh_meta(self):
        now = QtCore.QDateTime.currentDateTime().toString('HH:mm')
        self.meta.setText(f'{self.gamertag}    {now}')

    def _accept_current(self, *_):
        it = self.listw.currentItem()
        if it is None:
            return
        self._selection = it.text()
        self.accept()

    def _accept_action(self, action):
        self._selection = str(action)
        self.accept()

    def selected(self):
        if self._selection:
            return self._selection
        it = self.listw.currentItem()
        return it.text() if it else None

    def showEvent(self, e):
        super().showEvent(e)
        parent = self.parentWidget()
        if parent is not None:
            w = min(max(760, int(parent.width() * 0.56)), max(760, parent.width() - 120))
            h = min(max(420, int(parent.height() * 0.56)), max(420, parent.height() - 120))
            self.resize(w, h)
            x = parent.x() + max(20, int(parent.width() * 0.18))
            y = parent.y() + max(20, int(parent.height() * 0.12))
            self.move(max(0, x), max(0, y))
        self._refresh_meta()
        self._animate_open()

    def _animate_open(self):
        effect = QtWidgets.QGraphicsOpacityEffect(self)
        self.setGraphicsEffect(effect)
        effect.setOpacity(0.0)
        end_rect = self.geometry()
        start_rect = QtCore.QRect(end_rect.x() - max(24, end_rect.width() // 18), end_rect.y(), end_rect.width(), end_rect.height())
        self.setGeometry(start_rect)
        self._open_anim = QtCore.QParallelAnimationGroup(self)
        fade = QtCore.QPropertyAnimation(effect, b'opacity', self)
        fade.setDuration(190)
        fade.setStartValue(0.0)
        fade.setEndValue(1.0)
        fade.setEasingCurve(QtCore.QEasingCurve.OutCubic)
        slide = QtCore.QPropertyAnimation(self, b'geometry', self)
        slide.setDuration(230)
        slide.setStartValue(start_rect)
        slide.setEndValue(end_rect)
        slide.setEasingCurve(QtCore.QEasingCurve.OutCubic)
        self._open_anim.addAnimation(fade)
        self._open_anim.addAnimation(slide)
        self._open_anim.finished.connect(lambda: self.setGraphicsEffect(None))
        self._open_anim.start(QtCore.QAbstractAnimation.DeleteWhenStopped)

    def keyPressEvent(self, e):
        if e.key() in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.reject()
            return
        if e.key() in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter):
            self._accept_current()
            return
        super().keyPressEvent(e)


class GamesInlineOverlay(QtWidgets.QFrame):
    actionTriggered = QtCore.pyqtSignal(str)
    closed = QtCore.pyqtSignal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._items = []
        self._item_index = {}
        self.setObjectName('games_inline_overlay')
        self.setVisible(False)
        self.setFocusPolicy(QtCore.Qt.StrongFocus)
        self.setStyleSheet('''
            QFrame#games_inline_overlay {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #e9edf2, stop:1 #c0c8d2);
                border:2px solid rgba(234,242,249,0.9);
                border-radius:4px;
            }
            QLabel#gio_title { color:#27313d; font-size:38px; font-weight:900; }
            QLabel#gio_hint { color:#2f3a46; font-size:16px; font-weight:700; }
            QPushButton#gio_blade {
                text-align:left;
                padding:8px 10px;
                min-height:44px;
                background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #5dc044, stop:1 #3d9834);
                border:1px solid rgba(241,249,241,0.42);
                color:#f6fff6;
                font-size:18px;
                font-weight:800;
            }
            QPushButton#gio_blade:hover, QPushButton#gio_blade:focus { background:#6bcf52; }
            QListWidget#gio_list {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #dfe4e9, stop:1 #cfd6de);
                border:1px solid #9aa4b0;
                color:#1f2832;
                outline:none;
                font-size:24px;
                font-weight:800;
            }
            QListWidget#gio_list::item {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #7d8792, stop:1 #59636f);
                border:1px solid rgba(231,237,243,0.52);
                padding:8px;
                margin:4px;
                min-width:186px;
                min-height:210px;
                color:#eef4f8;
            }
            QListWidget#gio_list::item:selected {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #f3f5f8, stop:1 #d6dce3);
                color:#1e2a37;
                border:2px solid #5cbc43;
            }
            QFrame#gio_featured {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #525d68, stop:1 #3e4751);
                border:1px solid rgba(224,232,240,0.55);
            }
            QLabel#gio_featured_tag { color:rgba(224,233,240,0.95); font-size:13px; font-weight:800; }
            QLabel#gio_featured_title { color:#f6fbff; font-size:40px; font-weight:900; }
            QLabel#gio_featured_desc { color:rgba(236,244,251,0.92); font-size:22px; font-weight:700; }
            QLabel#gio_meta { color:#2f4155; font-size:17px; font-weight:800; }
            QPushButton#gio_btn {
                background:#4ea42a; color:#fff; border:1px solid #3b7f1f; padding:7px 12px; font-size:14px; font-weight:800;
            }
            QPushButton#gio_btn:hover, QPushButton#gio_btn:focus { background:#3f9120; }
        ''')
        root = QtWidgets.QVBoxLayout(self)
        root.setContentsMargins(12, 10, 12, 8)
        root.setSpacing(8)

        self.title = QtWidgets.QLabel('My Games')
        self.title.setObjectName('gio_title')
        root.addWidget(self.title, 0, QtCore.Qt.AlignLeft)

        blade_row = QtWidgets.QHBoxLayout()
        blade_row.setSpacing(6)
        self.blade_my_games = QtWidgets.QPushButton('My Games')
        self.blade_browse = QtWidgets.QPushButton('Browse Games')
        self.blade_search = QtWidgets.QPushButton('Search Games')
        for b in (self.blade_my_games, self.blade_browse, self.blade_search):
            b.setObjectName('gio_blade')
            blade_row.addWidget(b, 0)
        blade_row.addStretch(1)
        root.addLayout(blade_row)

        self.featured = QtWidgets.QFrame()
        self.featured.setObjectName('gio_featured')
        feat_l = QtWidgets.QVBoxLayout(self.featured)
        feat_l.setContentsMargins(12, 9, 12, 9)
        feat_l.setSpacing(3)
        self.featured_tag = QtWidgets.QLabel('HIGHLIGHT')
        self.featured_tag.setObjectName('gio_featured_tag')
        self.featured_title = QtWidgets.QLabel('My Games')
        self.featured_title.setObjectName('gio_featured_title')
        self.featured_desc = QtWidgets.QLabel('Installed games and quick launch library.')
        self.featured_desc.setObjectName('gio_featured_desc')
        self.featured_desc.setWordWrap(True)
        feat_l.addWidget(self.featured_tag, 0, QtCore.Qt.AlignLeft)
        feat_l.addStretch(1)
        feat_l.addWidget(self.featured_title, 0, QtCore.Qt.AlignLeft)
        feat_l.addWidget(self.featured_desc, 0, QtCore.Qt.AlignLeft)
        root.addWidget(self.featured, 0)

        self.listw = QtWidgets.QListWidget()
        self.listw.setObjectName('gio_list')
        self.listw.setViewMode(QtWidgets.QListView.IconMode)
        self.listw.setFlow(QtWidgets.QListView.LeftToRight)
        self.listw.setMovement(QtWidgets.QListView.Static)
        self.listw.setResizeMode(QtWidgets.QListView.Adjust)
        self.listw.setWrapping(False)
        self.listw.setHorizontalScrollMode(QtWidgets.QAbstractItemView.ScrollPerPixel)
        self.listw.setVerticalScrollBarPolicy(QtCore.Qt.ScrollBarAlwaysOff)
        self.listw.setSpacing(6)
        self.listw.setGridSize(QtCore.QSize(226, 252))
        self.listw.itemActivated.connect(self._play_current)
        self.listw.currentRowChanged.connect(self._update_meta)
        root.addWidget(self.listw, 1)

        self.meta = QtWidgets.QLabel('Select a game/app tile.')
        self.meta.setObjectName('gio_meta')
        root.addWidget(self.meta, 0, QtCore.Qt.AlignLeft)

        row = QtWidgets.QHBoxLayout()
        row.setSpacing(8)
        self.play_btn = QtWidgets.QPushButton('Play / Open')
        self.install_btn = QtWidgets.QPushButton('Install')
        self.uninstall_btn = QtWidgets.QPushButton('Uninstall')
        self.close_btn = QtWidgets.QPushButton('Close')
        for b in (self.play_btn, self.install_btn, self.uninstall_btn, self.close_btn):
            b.setObjectName('gio_btn')
            row.addWidget(b, 0)
        row.addStretch(1)
        root.addLayout(row)

        self.hint = QtWidgets.QLabel('A/ENTER = Open | X/SPACE = Install | Y/TAB = Uninstall | B/ESC = Back')
        self.hint.setObjectName('gio_hint')
        root.addWidget(self.hint, 0, QtCore.Qt.AlignLeft)

        self.play_btn.clicked.connect(self._play_current)
        self.install_btn.clicked.connect(self._install_current)
        self.uninstall_btn.clicked.connect(self._uninstall_current)
        self.close_btn.clicked.connect(self.close_overlay)
        self.blade_my_games.clicked.connect(lambda: self._focus_label('My Games'))
        self.blade_browse.clicked.connect(lambda: self.actionTriggered.emit('Browse Games'))
        self.blade_search.clicked.connect(lambda: self.actionTriggered.emit('Search Games'))

    def set_items(self, items, title='My Games'):
        self._items = list(items or [])
        self._item_index = {}
        self.title.setText(str(title or 'My Games'))
        self.listw.clear()
        for idx, item in enumerate(self._items):
            label = str(item.get('label', 'Item'))
            it = QtWidgets.QListWidgetItem(label)
            it.setData(QtCore.Qt.UserRole, dict(item))
            self.listw.addItem(it)
            self._item_index[label.strip().lower()] = idx
        if self.listw.count() > 0:
            self.listw.setCurrentRow(0)
        self._update_meta(self.listw.currentRow())

    def _focus_label(self, label):
        key = str(label or '').strip().lower()
        idx = self._item_index.get(key)
        if idx is None:
            return
        self.listw.setCurrentRow(int(idx))
        self.listw.scrollToItem(self.listw.item(int(idx)), QtWidgets.QAbstractItemView.PositionAtCenter)
        self.listw.setFocus()

    def _current_payload(self):
        it = self.listw.currentItem()
        if it is None:
            return {}
        data = it.data(QtCore.Qt.UserRole)
        return data if isinstance(data, dict) else {}

    def _update_meta(self, _row):
        data = self._current_payload()
        label = str(data.get('label', 'My Games')).strip() or 'My Games'
        desc = str(data.get('desc', 'Select a game/app tile.')).strip()
        self.meta.setText(desc or 'Select a game/app tile.')
        self.featured_title.setText(label)
        self.featured_desc.setText(desc or 'Select a game/app tile.')

    def _play_current(self):
        data = self._current_payload()
        action = str(data.get('play', '')).strip()
        if action:
            self.actionTriggered.emit(action)

    def _install_current(self):
        data = self._current_payload()
        action = str(data.get('install', '')).strip()
        if action:
            self.actionTriggered.emit(action)

    def _uninstall_current(self):
        data = self._current_payload()
        action = str(data.get('uninstall', '')).strip()
        if action:
            self.actionTriggered.emit(action)

    def open_overlay(self):
        self.setVisible(True)
        self.raise_()
        self.activateWindow()
        self.setFocus()
        self.listw.setFocus()
        effect = QtWidgets.QGraphicsOpacityEffect(self)
        self.setGraphicsEffect(effect)
        effect.setOpacity(0.0)
        end_rect = self.geometry()
        start_rect = QtCore.QRect(end_rect.x() + 20, end_rect.y(), end_rect.width(), end_rect.height())
        self.setGeometry(start_rect)
        grp = QtCore.QParallelAnimationGroup(self)
        fade = QtCore.QPropertyAnimation(effect, b'opacity', self)
        fade.setDuration(170)
        fade.setStartValue(0.0)
        fade.setEndValue(1.0)
        fade.setEasingCurve(QtCore.QEasingCurve.OutCubic)
        slide = QtCore.QPropertyAnimation(self, b'geometry', self)
        slide.setDuration(210)
        slide.setStartValue(start_rect)
        slide.setEndValue(end_rect)
        slide.setEasingCurve(QtCore.QEasingCurve.OutCubic)
        grp.addAnimation(fade)
        grp.addAnimation(slide)
        grp.finished.connect(lambda: self.setGraphicsEffect(None))
        grp.start(QtCore.QAbstractAnimation.DeleteWhenStopped)

    def close_overlay(self):
        if not self.isVisible():
            return
        self.setVisible(False)
        self.closed.emit()

    def keyPressEvent(self, e):
        k = e.key()
        if k in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.close_overlay()
            return
        if k in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter):
            self._play_current()
            return
        if k == QtCore.Qt.Key_Space:
            self._install_current()
            return
        if k == QtCore.Qt.Key_Tab:
            self._uninstall_current()
            return
        super().keyPressEvent(e)


class VirtualKeyboardDialog(QtWidgets.QDialog):
    def __init__(self, initial='', parent=None, sfx_cb=None):
        super().__init__(parent)
        self._play_sfx = sfx_cb
        self._nav_default_cols = 10
        self.setWindowTitle('Virtual Keyboard')
        self.setWindowFlags(QtCore.Qt.Dialog | QtCore.Qt.FramelessWindowHint)
        self.setModal(True)
        self.resize(920, 420)
        self.setStyleSheet('''
            QDialog { background:#d2d7dc; border:2px solid #e8edf1; }
            QLineEdit { background:#ffffff; border:1px solid #8a96a3; color:#1e2731; font-size:24px; font-weight:700; padding:8px; }
            QListWidget { background:#eef2f5; border:1px solid #9da8b3; color:#24303b; font-size:18px; font-weight:800; outline:none; }
            QListWidget::item { border:1px solid #c1c9d2; min-width:74px; min-height:46px; margin:4px; }
            QListWidget::item:selected { background:#66b340; color:#fff; border:2px solid #2f6e28; }
            QLabel { color:#2f3944; font-size:14px; font-weight:700; }
        ''')
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(12, 10, 12, 10)
        v.setSpacing(8)
        self.edit = QtWidgets.QLineEdit(str(initial or ''))
        self.edit.setFocusPolicy(QtCore.Qt.ClickFocus)
        self.edit.installEventFilter(self)
        v.addWidget(self.edit)
        self.keys = QtWidgets.QListWidget()
        self.keys.setViewMode(QtWidgets.QListView.IconMode)
        self.keys.setMovement(QtWidgets.QListView.Static)
        self.keys.setResizeMode(QtWidgets.QListView.Adjust)
        self.keys.setWrapping(True)
        self.keys.setSpacing(4)
        self.keys.setGridSize(QtCore.QSize(84, 54))
        self.keys.itemActivated.connect(self._activate_current)
        self.keys.installEventFilter(self)
        for token in list("1234567890QWERTYUIOPASDFGHJKLZXCVBNM") + ['-', '_', '@', '.', '/', ':', 'SPACE', 'BACK', 'CLEAR', 'DONE']:
            self.keys.addItem(QtWidgets.QListWidgetItem(token))
        self.keys.setCurrentRow(0)
        self.keys.setFocus(QtCore.Qt.OtherFocusReason)
        v.addWidget(self.keys, 1)
        v.addWidget(QtWidgets.QLabel('A/ENTER = Select | B/ESC = Back | X = Backspace | Y = Space'))

    def text(self):
        return self.edit.text()

    def _sfx(self):
        if callable(self._play_sfx):
            try:
                self._play_sfx('select')
            except Exception:
                pass

    def _activate_current(self):
        it = self.keys.currentItem()
        if it is None:
            return
        key = str(it.text() or '')
        self._sfx()
        if key == 'DONE':
            self.accept()
            return
        if key == 'SPACE':
            self.edit.setText(self.edit.text() + ' ')
            self.keys.setFocus(QtCore.Qt.OtherFocusReason)
            return
        if key == 'BACK':
            self.edit.setText(self.edit.text()[:-1])
            self.keys.setFocus(QtCore.Qt.OtherFocusReason)
            return
        if key == 'CLEAR':
            self.edit.setText('')
            self.keys.setFocus(QtCore.Qt.OtherFocusReason)
            return
        self.edit.setText(self.edit.text() + key)
        self.keys.setFocus(QtCore.Qt.OtherFocusReason)

    def _nav_cols(self):
        try:
            grid_w = int(self.keys.gridSize().width())
            view_w = int(self.keys.viewport().width())
            cols = max(1, view_w // max(1, grid_w))
            return cols
        except Exception:
            return self._nav_default_cols

    def _move_selection(self, dr=0, dc=0):
        total = int(self.keys.count())
        if total <= 0:
            return
        cols = max(1, int(self._nav_cols() or self._nav_default_cols))
        idx = int(self.keys.currentRow())
        if idx < 0:
            idx = 0
        row = idx // cols
        col = idx % cols
        row += int(dr)
        col += int(dc)
        max_row = (total - 1) // cols
        row = max(0, min(max_row, row))
        col = max(0, col)
        row_start = row * cols
        row_end = min(total - 1, row_start + cols - 1)
        new_idx = min(row_end, row_start + col)
        self.keys.setCurrentRow(new_idx)
        it = self.keys.currentItem()
        if it is not None:
            self.keys.scrollToItem(it, QtWidgets.QAbstractItemView.PositionAtCenter)

    def eventFilter(self, obj, event):
        if event.type() == QtCore.QEvent.KeyPress:
            if event.key() in (
                QtCore.Qt.Key_Left, QtCore.Qt.Key_Right,
                QtCore.Qt.Key_Up, QtCore.Qt.Key_Down,
                QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter,
                QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back,
                QtCore.Qt.Key_Space, QtCore.Qt.Key_Backspace,
            ):
                self.keyPressEvent(event)
                return True
        return super().eventFilter(obj, event)

    def keyPressEvent(self, e):
        k = e.key()
        if k in (QtCore.Qt.Key_Left,):
            self._move_selection(0, -1)
            return
        if k in (QtCore.Qt.Key_Right,):
            self._move_selection(0, 1)
            return
        if k in (QtCore.Qt.Key_Up,):
            self._move_selection(-1, 0)
            return
        if k in (QtCore.Qt.Key_Down,):
            self._move_selection(1, 0)
            return
        if k in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.reject()
            return
        if k in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter):
            self._activate_current()
            return
        if k == QtCore.Qt.Key_Space:
            self._sfx()
            self.edit.setText(self.edit.text() + ' ')
            self.keys.setFocus(QtCore.Qt.OtherFocusReason)
            return
        if k == QtCore.Qt.Key_Backspace:
            self._sfx()
            self.edit.setText(self.edit.text()[:-1])
            self.keys.setFocus(QtCore.Qt.OtherFocusReason)
            return
        super().keyPressEvent(e)


class EscInputDialog(QtWidgets.QInputDialog):
    def keyPressEvent(self, e):
        if e.key() in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.reject()
            return
        super().keyPressEvent(e)


class WebKioskWindow(QtWidgets.QMainWindow):
    def __init__(self, url, parent=None, sfx_cb=None):
        super().__init__(parent)
        self._play_sfx = sfx_cb
        self._gp = None
        self._gp_prev = {}
        self._gp_timer = None
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
        self._kbd = QtWidgets.QShortcut(QtGui.QKeySequence(QtCore.Qt.Key_F2), self)
        self._kbd.activated.connect(self._open_virtual_keyboard_for_page)
        self._kbd2 = QtWidgets.QShortcut(QtGui.QKeySequence('Ctrl+K'), self)
        self._kbd2.activated.connect(self._open_virtual_keyboard_for_page)
        self._guide = QtWidgets.QShortcut(QtGui.QKeySequence(QtCore.Qt.Key_F1), self)
        self._guide.activated.connect(self._show_guide)
        self._guide2 = QtWidgets.QShortcut(QtGui.QKeySequence(QtCore.Qt.Key_Home), self)
        self._guide2.activated.connect(self._show_guide)
        self._setup_gamepad()

    def _sfx(self, name='select'):
        if callable(self._play_sfx):
            try:
                self._play_sfx(name)
            except Exception:
                pass

    def _inject_text(self, text):
        payload = json.dumps(str(text or ''))
        js = f"""
(() => {{
  const el = document.activeElement;
  if (!el) return false;
  const tag = (el.tagName || '').toLowerCase();
  const tp = (el.type || '').toLowerCase();
  const editable = el.isContentEditable || tag === 'textarea' ||
    (tag === 'input' && !['button','submit','checkbox','radio','range','color','file','image','reset'].includes(tp));
  if (!editable) return false;
  const txt = {payload};
  if (el.isContentEditable) {{
    try {{ document.execCommand('insertText', false, txt); }} catch (_e) {{ el.textContent = (el.textContent || '') + txt; }}
  }} else {{
    el.value = (el.value || '') + txt;
  }}
  el.dispatchEvent(new Event('input', {{ bubbles: true }}));
  el.dispatchEvent(new Event('change', {{ bubbles: true }}));
  return true;
}})();
"""
        self.view.page().runJavaScript(js)

    def _open_virtual_keyboard_for_page(self):
        self._sfx('open')
        d = VirtualKeyboardDialog('', self, sfx_cb=self._play_sfx)
        if d.exec_() == QtWidgets.QDialog.Accepted:
            txt = d.text()
            if txt:
                self._inject_text(txt)
                self._sfx('select')
            return
        self._sfx('back')

    def _open_keyboard_if_editable(self):
        probe = """
(() => {
  const el = document.activeElement;
  if (!el) return false;
  const tag = (el.tagName || '').toLowerCase();
  const tp = (el.type || '').toLowerCase();
  return !!(el.isContentEditable || tag === 'textarea' ||
    (tag === 'input' && !['button','submit','checkbox','radio','range','color','file','image','reset'].includes(tp)));
})();
"""
        def cb(editable):
            if bool(editable):
                self._open_virtual_keyboard_for_page()
            else:
                self._forward_enter_to_view()
        self.view.page().runJavaScript(probe, cb)

    def _forward_enter_to_view(self):
        self.view.setFocus()
        press = QtGui.QKeyEvent(QtCore.QEvent.KeyPress, QtCore.Qt.Key_Return, QtCore.Qt.NoModifier)
        rel = QtGui.QKeyEvent(QtCore.QEvent.KeyRelease, QtCore.Qt.Key_Return, QtCore.Qt.NoModifier)
        QtWidgets.QApplication.postEvent(self.view, press)
        QtWidgets.QApplication.postEvent(self.view, rel)

    def _show_guide(self):
        parent = self.parentWidget()
        gamertag = 'Player1'
        if parent is not None and hasattr(parent, '_gamertag'):
            try:
                gamertag = str(parent._gamertag())
            except Exception:
                pass
        d = XboxGuideMenu(gamertag, self)
        if d.exec_() != QtWidgets.QDialog.Accepted:
            return
        sel = str(d.selected() or '').strip()
        if not sel:
            return
        if sel == 'Cerrar app actual':
            self.close()
            return
        if parent is not None and hasattr(parent, '_handle_xbox_guide_action'):
            try:
                parent._handle_xbox_guide_action(sel)
            except Exception:
                pass

    def _setup_gamepad(self):
        if QtGamepad is None:
            return
        try:
            mgr = QtGamepad.QGamepadManager.instance()
            ids = list(mgr.connectedGamepads())
            if not ids:
                return
            self._gp = QtGamepad.QGamepad(ids[0], self)
            self._gp_timer = QtCore.QTimer(self)
            self._gp_timer.timeout.connect(self._poll_gamepad)
            self._gp_timer.start(75)
        except Exception:
            self._gp = None

    def _gpv(self, name, default=0.0):
        gp = self._gp
        if gp is None:
            return default
        v = getattr(gp, name, None)
        try:
            return v() if callable(v) else v
        except Exception:
            return default

    def _send_key_to_view(self, key):
        self.view.setFocus()
        press = QtGui.QKeyEvent(QtCore.QEvent.KeyPress, key, QtCore.Qt.NoModifier)
        rel = QtGui.QKeyEvent(QtCore.QEvent.KeyRelease, key, QtCore.Qt.NoModifier)
        QtWidgets.QApplication.postEvent(self.view, press)
        QtWidgets.QApplication.postEvent(self.view, rel)

    def _go_back(self):
        self.view.back()

    def _go_forward(self):
        self.view.forward()

    def _poll_gamepad(self):
        gp = self._gp
        if gp is None:
            return
        cur = {
            'left': bool(self._gpv('buttonLeft', False)) or float(self._gpv('axisLeftX', 0.0)) < -0.6,
            'right': bool(self._gpv('buttonRight', False)) or float(self._gpv('axisLeftX', 0.0)) > 0.6,
            'up': bool(self._gpv('buttonUp', False)) or float(self._gpv('axisLeftY', 0.0)) < -0.6,
            'down': bool(self._gpv('buttonDown', False)) or float(self._gpv('axisLeftY', 0.0)) > 0.6,
            'a': bool(self._gpv('buttonA', False)),
            'b': bool(self._gpv('buttonB', False)),
            'x': bool(self._gpv('buttonX', False)),
            'y': bool(self._gpv('buttonY', False)),
            'guide': bool(self._gpv('buttonGuide', False)),
            'lb': bool(self._gpv('buttonL1', False)),
            'rb': bool(self._gpv('buttonR1', False)),
        }

        def pressed(name):
            return cur.get(name, False) and not self._gp_prev.get(name, False)

        if pressed('guide') or pressed('y'):
            self._show_guide()
        elif pressed('b'):
            self.close()
        elif pressed('x'):
            self._open_virtual_keyboard_for_page()
        elif pressed('lb'):
            self._go_back()
        elif pressed('rb'):
            self._go_forward()
        elif pressed('a'):
            self._open_keyboard_if_editable()
        elif pressed('left'):
            self._send_key_to_view(QtCore.Qt.Key_Left)
        elif pressed('right'):
            self._send_key_to_view(QtCore.Qt.Key_Right)
        elif pressed('up'):
            self._send_key_to_view(QtCore.Qt.Key_Up)
        elif pressed('down'):
            self._send_key_to_view(QtCore.Qt.Key_Down)
        self._gp_prev = cur

    def keyPressEvent(self, e):
        k = e.key()
        if k in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.close()
            return
        guide_keys = {QtCore.Qt.Key_F1, QtCore.Qt.Key_Home, QtCore.Qt.Key_Meta}
        key_super_l = getattr(QtCore.Qt, 'Key_Super_L', None)
        key_super_r = getattr(QtCore.Qt, 'Key_Super_R', None)
        if key_super_l is not None:
            guide_keys.add(key_super_l)
        if key_super_r is not None:
            guide_keys.add(key_super_r)
        if k in guide_keys:
            self._show_guide()
            return
        if k in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter):
            self._open_keyboard_if_editable()
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
        self._body_layout = None
        self.left_col = None
        self.left_layout = None
        self.center_layout = None
        self.right_col = None
        self.right_layout = None
        self._build()

    def _build_tiles(self, defs, target, layout, alignment=QtCore.Qt.AlignLeft, tile_opts=None):
        opts = dict(tile_opts or {})
        for action, text, size in defs:
            tile_size = size
            if opts.get('dense'):
                try:
                    tile_size = (int(size[0]), max(84, int(size[1] * 0.86)))
                except Exception:
                    tile_size = size
            tile = GreenTile(
                action,
                text,
                tile_size,
                icon_scale=float(opts.get('icon_scale', 1.0)),
                text_scale=float(opts.get('text_scale', 1.0)),
                dense=bool(opts.get('dense', False)),
            )
            tile.clicked.connect(self.actionTriggered.emit)
            target.append(tile)
            layout.addWidget(tile, 0, alignment)

    def _build(self):
        body = QtWidgets.QHBoxLayout(self)
        self._body_layout = body
        body.setContentsMargins(0, 0, 0, 0)
        body.setSpacing(26)
        body.addStretch(1)

        left_col = QtWidgets.QWidget()
        self.left_col = left_col
        left_col.setFixedWidth(320)
        left = QtWidgets.QVBoxLayout(left_col)
        self.left_layout = left
        left.setContentsMargins(0, 0, 0, 0)
        left.setSpacing(14)
        self._build_tiles(self.spec.get('left', []), self.left_tiles, left, QtCore.Qt.AlignLeft)
        left.addStretch(1)

        center_col = QtWidgets.QWidget()
        center = QtWidgets.QVBoxLayout(center_col)
        self.center_layout = center
        center.setContentsMargins(0, 0, 0, 0)
        center.setSpacing(14)
        hero_variant = str(self.spec.get('hero_variant', 'default')).strip().lower()
        if hero_variant == 'games':
            self.hero = GamesShowcasePanel(
                self.spec.get('hero_action', 'Games Hub'),
                self.spec.get('hero_title', self.name),
                self.spec.get('hero_subtitle', 'featured'),
            )
        else:
            self.hero = HeroPanel(
                self.spec.get('hero_action', 'Hub'),
                self.spec.get('hero_title', self.name),
                self.spec.get('hero_subtitle', 'featured'),
            )
        self.hero.clicked.connect(self.actionTriggered.emit)
        center.addWidget(self.hero, 0, alignment=QtCore.Qt.AlignHCenter)
        center.addStretch(1)

        right_col = QtWidgets.QWidget()
        self.right_col = right_col
        right_col.setFixedWidth(320)
        right = QtWidgets.QVBoxLayout(right_col)
        self.right_layout = right
        right.setContentsMargins(0, 0, 0, 0)
        right.setSpacing(14)
        self._build_tiles(
            self.spec.get('right', []),
            self.right_tiles,
            right,
            QtCore.Qt.AlignRight,
            tile_opts={'dense': True, 'icon_scale': 0.70, 'text_scale': 0.86},
        )
        right.addStretch(1)

        body.addWidget(left_col, 0, alignment=QtCore.Qt.AlignVCenter)
        body.addWidget(center_col, 0, alignment=QtCore.Qt.AlignVCenter)
        body.addWidget(right_col, 0, alignment=QtCore.Qt.AlignVCenter)
        body.addStretch(1)

    def apply_scale(self, scale=1.0, compact=False):
        s = max(0.62, float(scale))
        compact_factor = 0.86 if compact else 1.0
        col_w = max(170, int(320 * s * compact_factor))
        gap = max(8, int(26 * s * compact_factor))
        col_gap = max(6, int(14 * s * compact_factor))
        if self._body_layout is not None:
            self._body_layout.setSpacing(gap)
        if self.left_col is not None:
            self.left_col.setFixedWidth(col_w)
        if self.right_col is not None:
            self.right_col.setFixedWidth(col_w)
        if self.left_layout is not None:
            self.left_layout.setSpacing(col_gap)
        if self.center_layout is not None:
            self.center_layout.setSpacing(col_gap)
        if self.right_layout is not None:
            self.right_layout.setSpacing(col_gap)
        for tile in self.left_tiles + self.right_tiles:
            tile.apply_scale(s, compact)
        if self.hero is not None:
            self.hero.apply_scale(s, compact)


class AchievementToast(QtWidgets.QFrame):
    finished = QtCore.pyqtSignal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName('achievement_toast')
        self.setAttribute(QtCore.Qt.WA_TransparentForMouseEvents, True)
        self.setFixedSize(430, 84)
        self.setFocusPolicy(QtCore.Qt.NoFocus)
        self._compact = False
        self._scale = 1.0
        self._anim = None
        self._opacity = QtWidgets.QGraphicsOpacityEffect(self)
        self._opacity.setOpacity(0.0)
        self.setGraphicsEffect(self._opacity)
        self._build()
        self.hide()

    def _build(self):
        root = QtWidgets.QHBoxLayout(self)
        root.setContentsMargins(12, 10, 16, 10)
        root.setSpacing(10)

        icon_wrap = QtWidgets.QFrame()
        icon_wrap.setObjectName('ach_icon_wrap')
        icon_wrap.setFixedSize(56, 56)
        icon_layout = QtWidgets.QVBoxLayout(icon_wrap)
        icon_layout.setContentsMargins(0, 0, 0, 0)

        self.icon_lbl = QtWidgets.QLabel()
        self.icon_lbl.setObjectName('ach_icon')
        self.icon_lbl.setAlignment(QtCore.Qt.AlignCenter)
        self.icon_lbl.setFixedSize(40, 40)
        px = self.style().standardIcon(QtWidgets.QStyle.SP_DialogApplyButton).pixmap(22, 22)
        self.icon_lbl.setPixmap(px)
        icon_layout.addWidget(self.icon_lbl, 0, QtCore.Qt.AlignCenter)

        text_col = QtWidgets.QVBoxLayout()
        text_col.setContentsMargins(0, 0, 0, 0)
        text_col.setSpacing(2)
        self.title_lbl = QtWidgets.QLabel('Achievement unlocked')
        self.title_lbl.setObjectName('ach_title')
        self.name_lbl = QtWidgets.QLabel('Ready')
        self.name_lbl.setObjectName('ach_name')
        text_col.addWidget(self.title_lbl)
        text_col.addWidget(self.name_lbl)

        self.score_lbl = QtWidgets.QLabel('0G')
        self.score_lbl.setObjectName('ach_score')
        self.score_lbl.setAlignment(QtCore.Qt.AlignCenter)
        self.score_lbl.setFixedWidth(64)

        root.addWidget(icon_wrap, 0, QtCore.Qt.AlignVCenter)
        root.addLayout(text_col, 1)
        root.addWidget(self.score_lbl, 0, QtCore.Qt.AlignVCenter)

        self.setStyleSheet('''
            QFrame#achievement_toast {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #2d3138, stop:1 #5a5f66);
                border:2px solid rgba(255,255,255,0.28);
                border-radius:40px;
            }
            QFrame#ach_icon_wrap {
                background:qradialgradient(cx:0.35, cy:0.35, radius:0.9, fx:0.35, fy:0.35, stop:0 #3a4047, stop:1 #171d25);
                border:2px solid #79bd3b;
                border-radius:28px;
            }
            QLabel#ach_icon {
                color:#ecf4ea;
                border:none;
            }
            QLabel#ach_title {
                color:#f2f5f7;
                font-size:18px;
                font-weight:800;
            }
            QLabel#ach_name {
                color:rgba(239,246,249,0.9);
                font-size:15px;
                font-weight:700;
            }
            QLabel#ach_score {
                color:#9bdb64;
                font-size:18px;
                font-weight:900;
                border:none;
            }
        ''')

    def apply_scale(self, scale=1.0, compact=False):
        self._scale = max(0.62, float(scale))
        self._compact = bool(compact)
        cf = 0.9 if self._compact else 1.0
        w = max(320, int(430 * self._scale * cf))
        h = max(70, int(84 * self._scale * cf))
        self.setFixedSize(w, h)
        self.score_lbl.setFixedWidth(max(52, int(64 * self._scale)))

    def _target_pos(self):
        parent = self.parentWidget()
        if parent is None:
            return QtCore.QPoint(20, 20)
        margin_x = max(12, int(26 * self._scale))
        margin_y = max(10, int(24 * self._scale))
        x = margin_x
        y = max(margin_y, parent.height() - self.height() - margin_y)
        return QtCore.QPoint(x, y)

    def reposition(self):
        if self.isVisible():
            self.move(self._target_pos())

    def show_achievement(self, name, score=0):
        title = str(name or 'Achievement')
        self.title_lbl.setText('Achievement unlocked')
        self.name_lbl.setText(title)
        try:
            score_int = int(score)
        except Exception:
            score_int = 0
        self.score_lbl.setText(f'{max(0, score_int)}G')

        if self._anim is not None:
            self._anim.stop()
            self._anim = None

        target = self._target_pos()
        start = QtCore.QPoint(-self.width() - 30, target.y())
        end = QtCore.QPoint(-self.width() + 80, target.y())
        self.move(start)
        self._opacity.setOpacity(0.0)
        self.show()
        self.raise_()

        seq = QtCore.QSequentialAnimationGroup(self)
        fade_in = QtCore.QPropertyAnimation(self._opacity, b'opacity')
        fade_in.setDuration(220)
        fade_in.setStartValue(0.0)
        fade_in.setEndValue(1.0)
        fade_in.setEasingCurve(QtCore.QEasingCurve.OutCubic)

        slide_in = QtCore.QPropertyAnimation(self, b'pos')
        slide_in.setDuration(280)
        slide_in.setStartValue(start)
        slide_in.setEndValue(target)
        slide_in.setEasingCurve(QtCore.QEasingCurve.OutCubic)

        hold = QtCore.QPauseAnimation(1700)

        fade_out = QtCore.QPropertyAnimation(self._opacity, b'opacity')
        fade_out.setDuration(280)
        fade_out.setStartValue(1.0)
        fade_out.setEndValue(0.0)
        fade_out.setEasingCurve(QtCore.QEasingCurve.InCubic)

        slide_out = QtCore.QPropertyAnimation(self, b'pos')
        slide_out.setDuration(320)
        slide_out.setStartValue(target)
        slide_out.setEndValue(end)
        slide_out.setEasingCurve(QtCore.QEasingCurve.InCubic)

        grp_in = QtCore.QParallelAnimationGroup()
        grp_in.addAnimation(fade_in)
        grp_in.addAnimation(slide_in)
        grp_out = QtCore.QParallelAnimationGroup()
        grp_out.addAnimation(fade_out)
        grp_out.addAnimation(slide_out)

        seq.addAnimation(grp_in)
        seq.addAnimation(hold)
        seq.addAnimation(grp_out)

        def done():
            self.hide()
            self.finished.emit()

        seq.finished.connect(done)
        self._anim = seq
        self._anim.start(QtCore.QAbstractAnimation.DeleteWhenStopped)


class AchievementsHubDialog(QtWidgets.QDialog):
    def __init__(self, gamertag='Player1', parent=None):
        super().__init__(parent)
        self.gamertag = str(gamertag or 'Player1')
        self._rows = []
        self._filter = 'all'
        self._progress = {'total': 0, 'unlocked': 0, 'locked': 0, 'score_total': 0, 'score_unlocked': 0}
        self._stats = {'actions': 0, 'launches': 0, 'purchases': 0, 'missions': 0}
        self.setWindowTitle('Logros')
        self.setWindowFlags(QtCore.Qt.Dialog | QtCore.Qt.FramelessWindowHint)
        self.setModal(True)
        self.resize(980, 620)
        self.setStyleSheet('''
            QFrame#ach_panel {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #3a3f46, stop:1 #1e242b);
                border:2px solid rgba(214,223,235,0.52);
                border-radius:7px;
            }
            QLabel#ach_title {
                color:#eef4f8;
                font-size:28px;
                font-weight:800;
            }
            QLabel#ach_meta {
                color:rgba(235,242,248,0.78);
                font-size:16px;
                font-weight:600;
            }
            QListWidget#ach_list {
                background:rgba(236,239,242,0.93);
                color:#20252b;
                border:1px solid rgba(0,0,0,0.26);
                font-size:22px;
                outline:none;
            }
            QListWidget#ach_list::item {
                padding:5px 10px;
                border:1px solid transparent;
            }
            QListWidget#ach_list::item:selected {
                color:#f3fff2;
                background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #4ea93f, stop:1 #2f8832);
                border:1px solid rgba(255,255,255,0.25);
            }
            QFrame#ach_side {
                background:rgba(65,74,84,0.95);
                border:1px solid rgba(194,206,222,0.25);
            }
            QLabel#ach_stat {
                color:#eef5fb;
                font-size:15px;
                font-weight:700;
            }
            QLabel#ach_name {
                color:#f2f8fd;
                font-size:20px;
                font-weight:800;
            }
            QLabel#ach_desc {
                color:#dce6f0;
                font-size:14px;
                font-weight:600;
            }
            QPushButton#ach_btn {
                text-align:left;
                padding:7px 10px;
                color:#e9f1f8;
                font-size:16px;
                font-weight:700;
                background:rgba(34,43,54,0.92);
                border:1px solid rgba(186,205,224,0.24);
            }
            QPushButton#ach_btn:focus,
            QPushButton#ach_btn:hover {
                background:rgba(58,80,106,0.95);
                border:1px solid rgba(218,233,246,0.52);
            }
            QLabel#ach_hint {
                color:rgba(238,245,250,0.84);
                font-size:15px;
                font-weight:600;
            }
        ''')
        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        panel = QtWidgets.QFrame()
        panel.setObjectName('ach_panel')
        outer.addWidget(panel)

        root = QtWidgets.QVBoxLayout(panel)
        root.setContentsMargins(12, 10, 12, 10)
        root.setSpacing(8)

        top = QtWidgets.QHBoxLayout()
        title = QtWidgets.QLabel('Logros')
        title.setObjectName('ach_title')
        self.meta = QtWidgets.QLabel('')
        self.meta.setObjectName('ach_meta')
        top.addWidget(title)
        top.addStretch(1)
        top.addWidget(self.meta)
        root.addLayout(top)

        body = QtWidgets.QHBoxLayout()
        body.setSpacing(10)
        self.listw = QtWidgets.QListWidget()
        self.listw.setObjectName('ach_list')
        self.listw.itemActivated.connect(self._show_current_detail)
        self.listw.currentRowChanged.connect(self._refresh_detail)
        body.addWidget(self.listw, 4)

        side = QtWidgets.QFrame()
        side.setObjectName('ach_side')
        sl = QtWidgets.QVBoxLayout(side)
        sl.setContentsMargins(8, 8, 8, 8)
        sl.setSpacing(7)

        self.stats_lbl = QtWidgets.QLabel('')
        self.stats_lbl.setObjectName('ach_stat')
        self.stats_lbl.setWordWrap(True)
        sl.addWidget(self.stats_lbl, 0)

        self.name_lbl = QtWidgets.QLabel('Selecciona un logro')
        self.name_lbl.setObjectName('ach_name')
        self.name_lbl.setWordWrap(True)
        sl.addWidget(self.name_lbl, 0)

        self.desc_lbl = QtWidgets.QLabel('Detalles del logro.')
        self.desc_lbl.setObjectName('ach_desc')
        self.desc_lbl.setWordWrap(True)
        sl.addWidget(self.desc_lbl, 1)

        self.btn_all = QtWidgets.QPushButton('Ver Todos')
        self.btn_unlocked = QtWidgets.QPushButton('Ver Desbloqueados')
        self.btn_locked = QtWidgets.QPushButton('Ver Bloqueados')
        self.btn_refresh = QtWidgets.QPushButton('Actualizar')
        self.btn_back = QtWidgets.QPushButton('Volver')
        for b in (self.btn_all, self.btn_unlocked, self.btn_locked, self.btn_refresh, self.btn_back):
            b.setObjectName('ach_btn')
            sl.addWidget(b, 0)
        sl.addStretch(1)
        body.addWidget(side, 2)
        root.addLayout(body, 1)

        hint = QtWidgets.QLabel('A/ENTER = Detalle | X = Actualizar | B/ESC = Volver')
        hint.setObjectName('ach_hint')
        root.addWidget(hint)

        self.btn_all.clicked.connect(lambda: self._set_filter('all'))
        self.btn_unlocked.clicked.connect(lambda: self._set_filter('unlocked'))
        self.btn_locked.clicked.connect(lambda: self._set_filter('locked'))
        self.btn_refresh.clicked.connect(self.reload)
        self.btn_back.clicked.connect(self.reject)

        self._clock = QtCore.QTimer(self)
        self._clock.timeout.connect(self._refresh_meta)
        self._clock.start(1000)
        self.reload()

    def _refresh_meta(self):
        now = QtCore.QDateTime.currentDateTime().toString('HH:mm')
        unlocked = int(self._progress.get('unlocked', 0))
        total = int(self._progress.get('total', 0))
        self.meta.setText(f'{self.gamertag}    {now}    {unlocked}/{total}')

    def _filtered_rows(self):
        if self._filter == 'unlocked':
            return [r for r in self._rows if r.get('unlocked')]
        if self._filter == 'locked':
            return [r for r in self._rows if not r.get('unlocked')]
        return list(self._rows)

    def _apply_filter(self):
        rows = self._filtered_rows()
        self.listw.blockSignals(True)
        self.listw.clear()
        for row in rows:
            status = 'UNLOCKED' if row.get('unlocked') else 'LOCKED'
            title = str(row.get('title', 'Achievement'))
            score = int(row.get('score', 0) or 0)
            item = QtWidgets.QListWidgetItem(f'{status}  {title}    {score}G')
            item.setData(QtCore.Qt.UserRole, dict(row))
            self.listw.addItem(item)
        self.listw.blockSignals(False)
        if self.listw.count() > 0:
            self.listw.setCurrentRow(0)
        self._refresh_detail(self.listw.currentRow())

    def _set_filter(self, mode):
        self._filter = str(mode or 'all')
        self._apply_filter()

    def _current_payload(self):
        it = self.listw.currentItem()
        if it is None:
            return {}
        data = it.data(QtCore.Qt.UserRole)
        return data if isinstance(data, dict) else {}

    def _refresh_detail(self, _row):
        row = self._current_payload()
        if not row:
            self.name_lbl.setText('Selecciona un logro')
            self.desc_lbl.setText('Detalles del logro.')
            return
        title = str(row.get('title', 'Achievement')).strip() or 'Achievement'
        desc = str(row.get('desc', 'Sin descripcion.')).strip() or 'Sin descripcion.'
        score = int(row.get('score', 0) or 0)
        aid = str(row.get('id', '')).strip()
        unlocked = bool(row.get('unlocked', False))
        state = 'Desbloqueado' if unlocked else 'Bloqueado'
        self.name_lbl.setText(f'{title} ({score}G)')
        self.desc_lbl.setText(f'{desc}\n\nEstado: {state}\nID: {aid}')

    def _show_current_detail(self, *_):
        row = self._current_payload()
        if not row:
            return
        title = str(row.get('title', 'Achievement')).strip() or 'Achievement'
        desc = str(row.get('desc', 'Sin descripcion.')).strip() or 'Sin descripcion.'
        score = int(row.get('score', 0) or 0)
        unlocked = bool(row.get('unlocked', False))
        state = 'Desbloqueado' if unlocked else 'Bloqueado'
        QtWidgets.QMessageBox.information(
            self,
            title,
            f'{desc}\n\nEstado: {state}\nGamerscore: {score}G'
        )

    def reload(self):
        try:
            state = ensure_achievements(5000)
        except Exception:
            state = {'items': [], 'unlocked': [], 'stats': {}}
        items = state.get('items', [])
        if not isinstance(items, list):
            items = []
        unlocked_list = state.get('unlocked', [])
        if not isinstance(unlocked_list, list):
            unlocked_list = []
        unlocked_ts = {}
        for rec in unlocked_list:
            if not isinstance(rec, dict):
                continue
            aid = str(rec.get('id', '')).strip()
            if not aid:
                continue
            try:
                unlocked_ts[aid] = int(rec.get('ts', 0) or 0)
            except Exception:
                unlocked_ts[aid] = 0
        rows = []
        total_score = 0
        unlocked_score = 0
        for item in items:
            if not isinstance(item, dict):
                continue
            aid = str(item.get('id', '')).strip()
            if not aid:
                continue
            score = int(item.get('score', 0) or 0)
            unlocked = aid in unlocked_ts
            if unlocked:
                unlocked_score += score
            total_score += score
            rows.append({
                'id': aid,
                'title': str(item.get('title', aid)).strip() or aid,
                'desc': str(item.get('desc', '')).strip(),
                'score': score,
                'unlocked': unlocked,
                'ts': int(unlocked_ts.get(aid, 0) or 0),
            })
        rows.sort(key=lambda r: (0 if r.get('unlocked') else 1, -int(r.get('ts', 0)), -int(r.get('score', 0)), str(r.get('title', '')).lower()))
        self._rows = rows
        unlocked_n = sum(1 for r in rows if r.get('unlocked'))
        total_n = len(rows)
        self._progress = {
            'total': total_n,
            'unlocked': unlocked_n,
            'locked': max(0, total_n - unlocked_n),
            'score_total': int(total_score),
            'score_unlocked': int(unlocked_score),
        }
        stats = state.get('stats', {})
        if not isinstance(stats, dict):
            stats = {}
        self._stats = {
            'actions': int(stats.get('actions', 0) or 0),
            'launches': int(stats.get('launches', 0) or 0),
            'purchases': int(stats.get('purchases', 0) or 0),
            'missions': int(stats.get('missions', 0) or 0),
        }
        self.stats_lbl.setText(
            f'Logros: {unlocked_n}/{total_n}\n'
            f'Gamerscore: {self._progress["score_unlocked"]}/{self._progress["score_total"]}G\n'
            f'Actions: {self._stats["actions"]}\n'
            f'Launches: {self._stats["launches"]}\n'
            f'Purchases: {self._stats["purchases"]}\n'
            f'Missions: {self._stats["missions"]}'
        )
        self._refresh_meta()
        self._apply_filter()

    def keyPressEvent(self, e):
        if e.key() in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.reject()
            return
        if e.key() in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter):
            self._show_current_detail()
            return
        if e.key() == QtCore.Qt.Key_X:
            self.reload()
            return
        super().keyPressEvent(e)


class Dashboard(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()
        ensure_data()
        self.setWindowTitle('XUI - Xbox 360 Style')
        scr = QtWidgets.QApplication.primaryScreen()
        if scr is not None:
            g = scr.availableGeometry()
            self.resize(min(1600, g.width()), min(900, g.height()))
        else:
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
                'hero_variant': 'games',
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
                    ('FNAE', 'FNAE', (270, 130)),
                    ('Gem Match', 'Gem Match', (270, 130)),
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
                    ('Web Browser', 'Web Browser', (270, 130)),
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
                    ('WiFi Toggle', 'WiFi', (270, 130)),
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
        self._fullscreen_enforced = False
        self._ui_scale = 1.0
        self._compact_ui = False
        self._stage_layout = None
        self._achievement_queue = []
        self._achievement_queued_ids = set()
        self._achievement_last_sfx_at = 0.0
        self._achievement_toast = None
        self._startup_update_checked = False
        self._mandatory_update_timer = None
        self._mandatory_update_dialog_open = False
        self._mandatory_update_in_progress = False
        self._mandatory_update_proc = None
        self._mandatory_update_progress = None
        self._mandatory_update_output = ''
        self._install_task_proc = None
        self._install_task_progress = None
        self._install_task_output = ''
        self._install_task_success_msg = ''
        self._install_task_fail_msg = ''
        self._install_task_launch_cmd = ''
        self._install_task_label = 'App'
        self._guide_open_last_at = 0.0
        self._games_inline = None
        self._qgamepads = {}
        self._gp_last_emit = {}
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
        self._setup_achievement_toast()
        try:
            ensure_achievements(5000)
        except Exception:
            pass
        self._setup_qt_gamepad_input()
        self._apply_responsive_layout()
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
        self._stage_layout = stage_l
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

        self._games_inline = GamesInlineOverlay(stage)
        self._games_inline.actionTriggered.connect(self.handle_action)
        self._games_inline.closed.connect(lambda: self._play_sfx('back'))
        self._games_inline.hide()

        self.setStyleSheet('''
            QMainWindow {
                background:qlineargradient(x1:0.5,y1:0.0,x2:0.5,y2:1.0, stop:0 #2f343b, stop:0.45 #5f656e, stop:0.78 #c5ccd4, stop:1 #edf1f5);
            }
            QFrame#stage {
                background: rgba(255,255,255,0.06);
                border-radius: 2px;
            }
        ''')
        self.setCursor(QtGui.QCursor(QtCore.Qt.BlankCursor))
        root.setCursor(QtGui.QCursor(QtCore.Qt.BlankCursor))

    def _compute_ui_metrics(self):
        w = max(800, self.width())
        h = max(480, self.height())
        sw = w
        sh = h
        scr = QtWidgets.QApplication.primaryScreen()
        if scr is not None:
            g = scr.availableGeometry()
            sw = max(800, g.width())
            sh = max(480, g.height())
        rw = min(w, sw) / 1600.0
        rh = min(h, sh) / 900.0
        scale = max(0.62, min(1.0, min(rw, rh)))
        force_compact = os.environ.get('XUI_COMPACT_UI', '0') == '1'
        compact = force_compact or (min(w, sw) <= 1280) or (min(h, sh) <= 720)
        if compact:
            scale = min(scale, 0.8)
        if force_compact:
            scale = min(scale, 0.74)
        return scale, compact

    def _apply_responsive_layout(self):
        scale, compact = self._compute_ui_metrics()
        self._ui_scale = scale
        self._compact_ui = compact
        compact_factor = 0.72 if compact else 1.0
        if self._stage_layout is not None:
            side = max(22, int(150 * scale * compact_factor))
            top = max(12, int(70 * scale * compact_factor))
            bottom = max(12, int(50 * scale * compact_factor))
            spacing = max(8, int(18 * scale * compact_factor))
            self._stage_layout.setContentsMargins(side, top, side, bottom)
            self._stage_layout.setSpacing(spacing)
        if hasattr(self, 'top_tabs') and self.top_tabs is not None:
            self.top_tabs.apply_scale(scale, compact)
        if hasattr(self, 'desc') and self.desc is not None:
            desc_px = max(12, int(28 * scale * (0.82 if compact else 1.0)))
            self.desc.setStyleSheet(f'font-size:{desc_px}px; color:rgba(235,240,244,0.75);')
        for p in self.pages:
            p.apply_scale(scale, compact)
        if self._achievement_toast is not None:
            self._achievement_toast.apply_scale(scale, compact)
            self._achievement_toast.reposition()
        self._layout_overlays()

    def _layout_overlays(self):
        if self._games_inline is None:
            return
        parent = self._games_inline.parentWidget()
        if parent is None:
            return
        pw = max(640, parent.width())
        ph = max(420, parent.height())
        margin_x = max(18, int(pw * 0.035))
        top = max(72, int(ph * 0.14))
        bottom_margin = max(12, int(ph * 0.06))
        w = max(920, pw - (margin_x * 2))
        h = max(520, ph - top - bottom_margin)
        x = margin_x
        y = top
        self._games_inline.setGeometry(x, y, w, h)

    def showEvent(self, e):
        super().showEvent(e)
        QtCore.QTimer.singleShot(0, self._ensure_fullscreen)
        QtCore.QTimer.singleShot(0, self._apply_responsive_layout)
        if not self._startup_update_checked:
            self._startup_update_checked = True
            QtCore.QTimer.singleShot(260, self._check_mandatory_update_gate)
            self._start_mandatory_update_monitor()

    def _start_mandatory_update_monitor(self):
        if self._mandatory_update_timer is not None:
            return
        t = QtCore.QTimer(self)
        t.setInterval(120000)
        t.timeout.connect(self._check_mandatory_update_gate)
        t.start()
        self._mandatory_update_timer = t

    def resizeEvent(self, e):
        super().resizeEvent(e)
        self._apply_responsive_layout()

    def _ensure_fullscreen(self):
        if self._fullscreen_enforced:
            return
        self._fullscreen_enforced = True
        try:
            self.setWindowState(self.windowState() | QtCore.Qt.WindowFullScreen)
            self.showFullScreen()
            self.raise_()
            self.activateWindow()
        except Exception:
            pass

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
        from_end_x = -int(shift * 0.58)
        to_start_x = int(shift * 0.42)

        for i, page in enumerate(self.pages):
            if i not in (from_idx, to_idx):
                page.hide()
        from_w.setGeometry(rect)
        to_w.setGeometry(rect)
        from_w.move(0, 0)
        to_w.move(to_start_x, 0)
        from_w.show()
        to_w.show()
        to_w.raise_()

        from_fx = QtWidgets.QGraphicsOpacityEffect(from_w)
        to_fx = QtWidgets.QGraphicsOpacityEffect(to_w)
        from_fx.setOpacity(1.0)
        to_fx.setOpacity(0.0)
        from_w.setGraphicsEffect(from_fx)
        to_w.setGraphicsEffect(to_fx)

        self._tab_animating = True
        self._tab_anim_group = QtCore.QParallelAnimationGroup(self)

        anim_from = QtCore.QPropertyAnimation(from_w, b'pos')
        anim_from.setDuration(320)
        anim_from.setStartValue(QtCore.QPoint(0, 0))
        anim_from.setEndValue(QtCore.QPoint(from_end_x, 0))
        anim_from.setEasingCurve(QtCore.QEasingCurve.InOutCubic)

        anim_to = QtCore.QPropertyAnimation(to_w, b'pos')
        anim_to.setDuration(320)
        anim_to.setStartValue(QtCore.QPoint(to_start_x, 0))
        anim_to.setEndValue(QtCore.QPoint(0, 0))
        anim_to.setEasingCurve(QtCore.QEasingCurve.InOutCubic)

        fade_from = QtCore.QPropertyAnimation(from_fx, b'opacity')
        fade_from.setDuration(280)
        fade_from.setStartValue(1.0)
        fade_from.setEndValue(0.08)
        fade_from.setEasingCurve(QtCore.QEasingCurve.OutCubic)

        fade_to = QtCore.QPropertyAnimation(to_fx, b'opacity')
        fade_to.setDuration(300)
        fade_to.setStartValue(0.0)
        fade_to.setEndValue(1.0)
        fade_to.setEasingCurve(QtCore.QEasingCurve.OutCubic)

        self._tab_anim_group.addAnimation(anim_from)
        self._tab_anim_group.addAnimation(anim_to)
        self._tab_anim_group.addAnimation(fade_from)
        self._tab_anim_group.addAnimation(fade_to)

        def done():
            self.page_stack.setCurrentIndex(to_idx)
            self._normalize_page_visibility(to_idx)
            from_w.setGraphicsEffect(None)
            to_w.setGraphicsEffect(None)
            self._tab_animating = False
            self._tab_anim_group = None
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

    def _open_games_hub_menu(self):
        self._play_sfx('open')
        if self._games_inline is None:
            return
        items = [
            {
                'label': 'My Games',
                'play': 'My Games',
                'install': 'Games Marketplace',
                'uninstall': '',
                'desc': 'Installed games and quick launch library.',
            },
            {
                'label': 'Steam',
                'play': 'Steam',
                'install': 'Install Steam',
                'uninstall': '',
                'desc': 'Steam integration and launcher.',
            },
            {
                'label': 'RetroArch',
                'play': 'RetroArch',
                'install': 'Install RetroArch',
                'uninstall': '',
                'desc': 'RetroArch integration for local ROM libraries.',
            },
            {
                'label': 'FNAE',
                'play': 'FNAE',
                'install': 'FNAE',
                'uninstall': 'Uninstall FNAE',
                'desc': 'Five Nights At Epstein\'s: install, play or uninstall.',
            },
            {
                'label': 'Gem Match',
                'play': 'Gem Match',
                'install': '',
                'uninstall': '',
                'desc': 'Arcade match-3 game.',
            },
            {
                'label': 'Runner',
                'play': 'Runner',
                'install': '',
                'uninstall': '',
                'desc': 'Arcade runner game.',
            },
            {
                'label': 'Casino',
                'play': 'Casino',
                'install': '',
                'uninstall': '',
                'desc': 'Casino mini game.',
            },
            {
                'label': 'Games Marketplace',
                'play': 'Games Marketplace',
                'install': '',
                'uninstall': '',
                'desc': 'Open store catalog with game/apps rotations.',
            },
            {
                'label': 'Disc & Local Media',
                'play': 'Disc & Local Media',
                'install': '',
                'uninstall': '',
                'desc': 'Scan tray/USB and launch local media games.',
            },
        ]
        self._games_inline.set_items(items, title='Games')
        self._layout_overlays()
        self._games_inline.open_overlay()

    def _extract_json_blob(self, text):
        raw = str(text or '').strip()
        if not raw:
            return None
        a = raw.find('{')
        b = raw.rfind('}')
        if a < 0 or b < 0 or b <= a:
            return None
        try:
            return json.loads(raw[a:b+1])
        except Exception:
            return None

    def _mandatory_update_payload(self):
        checker = XUI_HOME / 'bin' / 'xui_update_check.sh'
        if not checker.exists():
            return None
        cmd = f'/bin/sh -c "{checker} mandatory --json"'
        out = subprocess.getoutput(cmd)
        return self._extract_json_blob(out)

    def _launch_mandatory_updater_and_quit(self):
        checker = XUI_HOME / 'bin' / 'xui_update_check.sh'
        if not checker.exists():
            QtWidgets.QApplication.quit()
            return
        if self._mandatory_update_proc is not None:
            if self._mandatory_update_proc.state() != QtCore.QProcess.NotRunning:
                return
        self._mandatory_update_in_progress = True
        self._mandatory_update_output = ''
        self._play_sfx('open')

        progress = UpdateProgressDialog(self)
        progress.show()
        self._mandatory_update_progress = progress

        proc = QtCore.QProcess(self)
        env = QtCore.QProcessEnvironment.systemEnvironment()
        env.insert('AUTO_CONFIRM', '1')
        env.insert('XUI_SKIP_LAUNCH_PROMPT', '1')
        proc.setProcessEnvironment(env)
        proc.setProgram('/bin/sh')
        proc.setArguments(['-lc', f'"{checker}" apply'])
        proc.setProcessChannelMode(QtCore.QProcess.MergedChannels)
        proc.readyReadStandardOutput.connect(self._on_mandatory_update_output)
        proc.finished.connect(self._on_mandatory_update_finished)
        proc.errorOccurred.connect(self._on_mandatory_update_error)
        self._mandatory_update_proc = proc
        proc.start()

    def _close_mandatory_update_progress(self):
        dlg = self._mandatory_update_progress
        self._mandatory_update_progress = None
        if dlg is None:
            return
        try:
            dlg.hide()
        except Exception:
            pass
        try:
            dlg.deleteLater()
        except Exception:
            pass

    def _on_mandatory_update_output(self):
        proc = self._mandatory_update_proc
        if proc is None:
            return
        try:
            chunk = bytes(proc.readAllStandardOutput()).decode('utf-8', errors='ignore')
        except Exception:
            chunk = ''
        if not chunk:
            return
        self._mandatory_update_output = (self._mandatory_update_output + chunk)[-22000:]
        dlg = self._mandatory_update_progress
        if dlg is None:
            return
        lines = [ln.strip() for ln in self._mandatory_update_output.splitlines() if ln.strip()]
        tail = lines[-1][:160] if lines else 'Applying mandatory update from GitHub...'
        if hasattr(dlg, 'set_detail'):
            dlg.set_detail(tail)

    def _restart_dashboard_after_update(self):
        helper = XUI_HOME / 'bin' / 'xui_postupdate_restart.sh'
        script = '''#!/usr/bin/env bash
set -euo pipefail
WRAP="$HOME/.xui/bin/xui_startup_and_dashboard.sh"
OLD_PID="${1:-}"

dashboard_running(){
  if ! command -v pgrep >/dev/null 2>&1; then
    return 1
  fi
  pgrep -u "$(id -u)" -f "pyqt_dashboard_improved.py" >/dev/null 2>&1
}

wait_old_dashboard_exit(){
  local pid="$1"
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  if [ "$pid" -le 1 ]; then
    return 0
  fi
  for _ in $(seq 1 140); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.10
  done
}

restart_via_systemd(){
  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user restart xui-dashboard.service >/dev/null 2>&1
}

start_via_wrapper(){
  if [ -x "$WRAP" ]; then
    nohup "$WRAP" >/dev/null 2>&1 &
    return 0
  fi
  return 1
}

wait_old_dashboard_exit "$OLD_PID"
sleep 0.20

if dashboard_running; then
  exit 0
fi

restart_via_systemd || true
for _ in $(seq 1 45); do
  if dashboard_running; then
    exit 0
  fi
  sleep 0.15
done

start_via_wrapper || true
for _ in $(seq 1 45); do
  if dashboard_running; then
    exit 0
  fi
  sleep 0.15
done

restart_via_systemd || true
start_via_wrapper || true
exit 0
'''
        try:
            helper.parent.mkdir(parents=True, exist_ok=True)
            helper.write_text(script, encoding='utf-8')
            helper.chmod(0o755)
        except Exception:
            pass
        helper_q = shlex.quote(str(helper))
        current_pid_q = shlex.quote(str(os.getpid()))
        cmd = (
            f'if [ -x {helper_q} ]; then '
            'if command -v systemd-run >/dev/null 2>&1; then '
            f'systemd-run --user --quiet --collect --unit "xui-postupdate-restart-$(date +%s)" {helper_q} {current_pid_q} >/dev/null 2>&1 || nohup {helper_q} {current_pid_q} >/dev/null 2>&1 & '
            'else '
            f'nohup {helper_q} {current_pid_q} >/dev/null 2>&1 & '
            'fi; '
            'fi'
        )
        QtCore.QProcess.startDetached('/bin/sh', ['-lc', cmd])
        QtCore.QTimer.singleShot(340, QtWidgets.QApplication.quit)

    def _on_mandatory_update_error(self, err):
        self._on_mandatory_update_output()
        self._close_mandatory_update_progress()
        proc = self._mandatory_update_proc
        self._mandatory_update_proc = None
        if proc is not None:
            proc.deleteLater()
        self._mandatory_update_in_progress = False
        try:
            err_code = int(err)
        except Exception:
            err_code = str(err)
        self._msg('Update Failed', f'Updater process error: {err_code}')
        QtCore.QTimer.singleShot(250, self._check_mandatory_update_gate)

    def _on_mandatory_update_finished(self, code, status):
        self._on_mandatory_update_output()
        proc = self._mandatory_update_proc
        self._mandatory_update_proc = None
        if proc is not None:
            proc.deleteLater()
        self._mandatory_update_in_progress = False
        ok = (status == QtCore.QProcess.NormalExit and int(code) == 0)
        if ok:
            dlg = self._mandatory_update_progress
            if dlg is not None and hasattr(dlg, 'finish_ok'):
                dlg.finish_ok()
                QtCore.QTimer.singleShot(360, self._close_mandatory_update_progress)
            else:
                self._close_mandatory_update_progress()
            self._msg('Update', 'Mandatory update installed. Restarting dashboard...')
            QtCore.QTimer.singleShot(420, self._restart_dashboard_after_update)
            return
        self._close_mandatory_update_progress()
        lines = [ln for ln in self._mandatory_update_output.splitlines() if ln.strip()]
        tail = '\n'.join(lines[-14:]).strip()
        if not tail:
            tail = f'Updater finished with exit code: {int(code)}'
        self._msg(
            'Update Failed',
            'Could not apply mandatory update.\n\n'
            + tail
            + '\n\nFix network/git access and try again.',
        )
        QtCore.QTimer.singleShot(250, self._check_mandatory_update_gate)

    def _check_mandatory_update_gate(self):
        if self._mandatory_update_in_progress:
            return
        if self._mandatory_update_dialog_open:
            return
        if not self.isVisible():
            return
        if QtWidgets.QApplication.activeModalWidget() is not None:
            return
        payload = self._mandatory_update_payload()
        if not isinstance(payload, dict):
            return
        if not bool(payload.get('checked', False)):
            return
        if not bool(payload.get('update_required', False)):
            return
        self._play_sfx('open')
        self._mandatory_update_dialog_open = True
        d = MandatoryUpdateDialog(payload, self)
        selected = 'No'
        if d.exec_() == QtWidgets.QDialog.Accepted:
            selected = d.selected_choice()
        self._mandatory_update_dialog_open = False
        if str(selected).strip().lower() == 'yes':
            self._launch_mandatory_updater_and_quit()
            return
        QtWidgets.QApplication.quit()

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

    def _setup_achievement_toast(self):
        self._achievement_toast = AchievementToast(self)
        self._achievement_toast.finished.connect(self._on_achievement_toast_finished)
        self._achievement_toast.apply_scale(self._ui_scale, self._compact_ui)

    def _queue_achievement_unlocks(self, rows):
        if not rows:
            return
        for row in rows:
            if isinstance(row, dict):
                aid = str(row.get('id', '')).strip()
                if aid and aid in self._achievement_queued_ids:
                    continue
                self._achievement_queue.append(row)
                if aid:
                    self._achievement_queued_ids.add(aid)
        if self._achievement_toast is None:
            return
        if not self._achievement_toast.isVisible():
            self._show_next_achievement_toast()

    def _show_next_achievement_toast(self):
        if self._achievement_toast is None:
            return
        if not self._achievement_queue:
            return
        row = self._achievement_queue.pop(0)
        aid = str(row.get('id', '')).strip()
        if aid and aid in self._achievement_queued_ids:
            self._achievement_queued_ids.discard(aid)
        title = str(row.get('title') or row.get('id') or 'Achievement')
        score = int(row.get('score', 0) or 0)
        now = time.monotonic()
        if (now - float(self._achievement_last_sfx_at)) > 0.75:
            self._play_sfx('achievement')
            self._achievement_last_sfx_at = now
        self._achievement_toast.show_achievement(title, score=score)

    def _on_achievement_toast_finished(self):
        if not self._achievement_queue:
            return
        QtCore.QTimer.singleShot(80, self._show_next_achievement_toast)

    def _unlock_achievement_event(self, kind, value):
        try:
            fresh = unlock_for_event(kind, value, limit=4)
        except Exception:
            fresh = []
        if fresh:
            self._queue_achievement_unlocks(fresh)

    def _launch_event_keys(self, action):
        mapping = {
            'casino': ('casino', 'game_casino'),
            'runner': ('runner', 'game_runner'),
            'gem_match': ('gem_match', 'minigame_bejeweled_xui'),
            'bejeweled': ('gem_match', 'minigame_bejeweled_xui'),
            'fnae': ('fnae', 'game_fnae_fangame'),
            'five_night_s_at_epstein_s': ('fnae', 'game_fnae_fangame'),
            'five_nights_at_epstein_s': ('fnae', 'game_fnae_fangame'),
            'steam': ('steam', 'platform_steam'),
            'retroarch': ('retroarch', 'platform_retroarch'),
            'lutris': ('lutris', 'platform_lutris'),
            'heroic': ('heroic', 'platform_heroic'),
            'store': ('store', 'xui_store_modern'),
            'avatar_store': ('store', 'xui_store_modern'),
            'web_browser': ('web_browser', 'browser_xui_webhub'),
            'media_player': ('media_player',),
            'boot_video': ('boot_video',),
            'playlist': ('playlist',),
            'visualizer': ('visualizer',),
            'system_music': ('system_music',),
            'netflix': ('netflix',),
            'youtube': ('youtube',),
            'kodi': ('kodi',),
            'app_launcher': ('app_launcher',),
            'missions': ('missions', 'game_missions'),
            'misiones': ('missions', 'game_missions'),
            'xui_web_browser': ('web_browser', 'browser_xui_webhub'),
        }
        key = ''.join(ch.lower() if ch.isalnum() else '_' for ch in str(action or '')).strip('_')
        while '__' in key:
            key = key.replace('__', '_')
        return mapping.get(key, ())

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
        QtCore.QProcess.startDetached('/bin/bash', ['-lc', hold])

    def _close_install_task_progress(self):
        dlg = self._install_task_progress
        self._install_task_progress = None
        if dlg is None:
            return
        try:
            dlg.hide()
        except Exception:
            pass
        try:
            dlg.deleteLater()
        except Exception:
            pass

    def _on_install_task_output(self):
        proc = self._install_task_proc
        if proc is None:
            return
        try:
            chunk = bytes(proc.readAllStandardOutput()).decode('utf-8', errors='ignore')
        except Exception:
            chunk = ''
        if not chunk:
            return
        self._install_task_output = (self._install_task_output + chunk)[-26000:]
        dlg = self._install_task_progress
        if dlg is None:
            return
        lines = [ln.strip() for ln in self._install_task_output.splitlines() if ln.strip()]
        if lines:
            dlg.set_detail(lines[-1][:180])

    def _on_install_task_error(self, err):
        self._on_install_task_output()
        proc = self._install_task_proc
        self._install_task_proc = None
        if proc is not None:
            proc.deleteLater()
        dlg = self._install_task_progress
        if dlg is not None and hasattr(dlg, 'finish_error'):
            dlg.finish_error('Installer process error.')
        self._close_install_task_progress()
        self._msg('Install Failed', f'Installer process error: {err}')

    def _on_install_task_finished(self, code, status):
        self._on_install_task_output()
        proc = self._install_task_proc
        self._install_task_proc = None
        if proc is not None:
            proc.deleteLater()
        ok = (status == QtCore.QProcess.NormalExit and int(code) == 0)
        if ok:
            dlg = self._install_task_progress
            if dlg is not None and hasattr(dlg, 'finish_ok'):
                dlg.finish_ok('Install completed successfully.')
            QtCore.QTimer.singleShot(260, self._close_install_task_progress)
            success_txt = str(self._install_task_success_msg or f'{self._install_task_label} installed.')
            launch_cmd = str(self._install_task_launch_cmd or '').strip()
            if launch_cmd:
                self._run('/bin/sh', ['-c', launch_cmd])
            self._msg('Install', success_txt)
            return
        dlg = self._install_task_progress
        if dlg is not None and hasattr(dlg, 'finish_error'):
            dlg.finish_error('Install failed.')
        self._close_install_task_progress()
        lines = [ln.strip() for ln in self._install_task_output.splitlines() if ln.strip()]
        tail = '\n'.join(lines[-10:]).strip()
        fail_txt = str(self._install_task_fail_msg or f'{self._install_task_label} install failed.')
        if tail:
            fail_txt = fail_txt + '\n\n' + tail
        self._msg('Install Failed', fail_txt)

    def _run_install_task(self, title, shell_cmd, success_msg='', fail_msg='', launch_cmd=''):
        if self._install_task_proc is not None and self._install_task_proc.state() != QtCore.QProcess.NotRunning:
            self._msg('Install', 'Another installation is already running.')
            return
        self._play_sfx('open')
        self._install_task_output = ''
        self._install_task_success_msg = str(success_msg or '')
        self._install_task_fail_msg = str(fail_msg or '')
        self._install_task_launch_cmd = str(launch_cmd or '')
        self._install_task_label = str(title or 'App')
        dlg = InstallTaskProgressDialog(self._install_task_label, self)
        dlg.show()
        self._install_task_progress = dlg
        proc = QtCore.QProcess(self)
        env = QtCore.QProcessEnvironment.systemEnvironment()
        env.insert('XUI_NONINTERACTIVE', '1')
        env.insert('XUI_FORCE_ELEVATED', '1')
        env.insert('DEBIAN_FRONTEND', 'noninteractive')
        proc.setProcessEnvironment(env)
        proc.setProgram('/bin/sh')
        proc.setArguments(['-lc', str(shell_cmd)])
        proc.setProcessChannelMode(QtCore.QProcess.MergedChannels)
        proc.readyReadStandardOutput.connect(self._on_install_task_output)
        proc.finished.connect(self._on_install_task_finished)
        proc.errorOccurred.connect(self._on_install_task_error)
        self._install_task_proc = proc
        proc.start()

    def _open_url(self, url):
        if QtWebEngineWidgets is not None:
            try:
                w = WebKioskWindow(url, self, sfx_cb=self._play_sfx)
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
            self._unlock_achievement_event('launch', key)
            return
        ask = self._ask_yes_no(
            label,
            f'{label} is not installed yet.\n\nDo you want to run installer now?'
        )
        if ask:
            if Path(install_script).exists():
                self._run_install_task(
                    label,
                    f'"{install_script}"',
                    success_msg=f'{label} install completed.',
                    fail_msg=f'{label} install failed.',
                    launch_cmd=f'"{launch_script}"',
                )
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
            self._run_install_task(
                spec['label'],
                f'"{install_script}"',
                success_msg=f'{spec["label"]} install completed.',
                fail_msg=f'{spec["label"]} install failed.',
            )
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
        d = VirtualKeyboardDialog(text, self, sfx_cb=self._play_sfx)
        d.setWindowTitle(title)
        if d.exec_() == QtWidgets.QDialog.Accepted:
            return d.text(), True
        return str(text or ''), False

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

    def _xbox_guide_recent_text(self):
        arr = safe_json_read(RECENT_FILE, [])
        if not isinstance(arr, list) or not arr:
            return 'No hay actividad reciente todavia.'
        lines = []
        for i, item in enumerate(arr[:12], 1):
            lines.append(f'{i:02d}. {item}')
        return '\n'.join(lines)

    def _xbox_guide_recent_messages_text(self):
        arr = safe_json_read(SOCIAL_MESSAGES_FILE, [])
        if not isinstance(arr, list) or not arr:
            return 'No hay mensajes recientes todavia.'
        lines = []
        for i, item in enumerate(arr[:18], 1):
            if isinstance(item, dict):
                who = str(item.get('from', 'Unknown'))
                txt = str(item.get('text', ''))
                lines.append(f'{i:02d}. {who}: {txt}')
            else:
                lines.append(f'{i:02d}. {item}')
        return '\n'.join(lines)

    def _xbox_guide_downloads_text(self):
        cmd = (
            "/bin/sh -c \"ps -eo comm,args 2>/dev/null | "
            "egrep -i 'steam|flatpak|apt|dnf|pacman|aria2c|transmission|qbittorrent|wget|curl' "
            "| grep -v egrep | head -n 12\""
        )
        out = subprocess.getoutput(cmd).strip()
        if out:
            return f'Procesos de descarga detectados:\n{out}'
        return 'No se detectan descargas activas.'

    def _show_xbox_guide(self):
        now = time.monotonic()
        if (now - float(self._guide_open_last_at)) < 0.65:
            return
        self._guide_open_last_at = now
        self._play_sfx('open')
        d = XboxGuideMenu(current_gamertag(), self)
        if d.exec_() == QtWidgets.QDialog.Accepted:
            opt = d.selected()
            if opt:
                self._play_sfx('select')
                self._handle_xbox_guide_action(opt)
        else:
            self._play_sfx('back')

    def _open_achievements_hub(self):
        self._play_sfx('open')
        d = AchievementsHubDialog(current_gamertag(), self)
        if d.exec_() == QtWidgets.QDialog.Accepted:
            self._play_sfx('select')
        else:
            self._play_sfx('back')

    def _handle_xbox_guide_action(self, action):
        name = str(action or '').strip()
        if not name:
            return
        if name == 'Logros':
            self._open_achievements_hub()
            return
        if name == 'Premios':
            self.handle_action('Store')
            return
        if name == 'Reciente':
            self._msg('Reciente', self._xbox_guide_recent_text())
            return
        if name == 'Mensajes recientes':
            self._msg('Mensajes recientes', self._xbox_guide_recent_messages_text())
            return
        if name == 'Social global':
            self._open_social_chat()
            return
        if name == 'Mis juegos':
            if 'games' in self.tabs:
                self._switch_tab(self.tabs.index('games'), animate=True, keep_tabs_focus=True)
            return
        if name == 'Descargas activas':
            self._msg('Descargas activas', self._xbox_guide_downloads_text())
            return
        if name == 'Canjear codigo':
            code, ok = self._input_text('Canjear codigo', 'Introduce tu codigo:', '')
            if not ok:
                return
            code = ''.join(ch for ch in str(code).upper() if ch.isalnum() or ch == '-')
            if not code:
                self._msg('Canjear codigo', 'Codigo no valido.')
                return
            store_file = DATA_HOME / 'redeemed_codes.json'
            redeemed = safe_json_read(store_file, [])
            if not isinstance(redeemed, list):
                redeemed = []
            if code in redeemed:
                self._msg('Canjear codigo', f'El codigo {code} ya fue usado en este perfil.')
                return
            redeemed.append(code)
            safe_json_write(store_file, redeemed)
            self._msg('Canjear codigo', f'Codigo {code} guardado correctamente.')
            return
        if name == 'Configuracion':
            if 'settings' in self.tabs:
                self._switch_tab(self.tabs.index('settings'), animate=True, keep_tabs_focus=True)
            return
        if name == 'Inicio de Xbox':
            if 'home' in self.tabs:
                self._switch_tab(self.tabs.index('home'), animate=True, keep_tabs_focus=True)
            return
        if name == 'Cerrar app actual':
            self.handle_action('Close Active App')
            return
        if name == 'Cerrar sesion':
            prof = safe_json_read(PROFILE_FILE, {})
            if not isinstance(prof, dict):
                prof = {}
            prof['signed_in'] = False
            safe_json_write(PROFILE_FILE, prof)
            self._msg('Sesion', 'Sesion cerrada.')
            return
        self._msg('Guia Xbox', f'Opcion no implementada: {name}')

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
        self._unlock_achievement_event('launch', Path(target).stem)
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
            'My Games': 'Open your personal games list (installed and ready to launch).',
            'Browse Games': 'Open catalog and browse game offers.',
            'Search Games': 'Search game titles in store.',
            'Games Marketplace': 'Open Games marketplace tiles and offers.',
            'Recently Played': 'Show recently used games and apps.',
            'Arcade Picks': 'Quick access to arcade style games.',
            'Disc & Local Media': 'Scan tray/USB media for launchable games.',
            'Platforms Status': 'Show installation/status of integrated game platforms.',
            'Install RetroArch': 'Install RetroArch from package manager or Flatpak.',
            'Install Lutris': 'Install Lutris from package manager or Flatpak.',
            'Install Heroic': 'Install Heroic Games Launcher.',
            'Store': 'Open XUI store and inventory.',
            'Web Browser': 'Open XUI Web Hub browser (Chromium based via Qt WebEngine).',
            'FNAE': "Launch Five Night's At Epstein's from local store package.",
            'Gem Match': 'Launch Gem Match minigame (Bejeweled style).',
            'Close Active App': 'Try to close the currently active external window/app.',
            'Casino': 'Launch casino minigame.',
            'Runner': 'Launch runner minigame.',
            'Missions': 'Open achievements hub (5000 logros) inside dashboard.',
            'Misiones': 'Open achievements hub (5000 logros) inside dashboard.',
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
            'Gamepad Test': 'Run interactive gamepad test tool (evdev/jstest).',
            'Controller Probe': 'Detect Joy-Con/Xbox controllers and show VID/PID + listener log.',
            'Controller Mappings': 'Show default dashboard mappings for Joy-Con and Xbox pads.',
            'Controller L4T Fix': 'Load L4T controller modules/services (hid_nintendo/xpad/joycond).',
            'Controller Profile': 'Select controller mapping profile (auto/xbox360/switch).',
            'Diagnostics': 'Run diagnostics helper.',
            'Update Check': 'Checks mandatory GitHub update status (repo afitler79-alt/XUI-X360-FRONTEND).',
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
        # Avoid false-positive achievement spam when only navigating tiles.
        # Real unlock events should come from launches/purchases/missions.
        for launch_key in self._launch_event_keys(action):
            self._unlock_achievement_event('launch', launch_key)
        xui = str(XUI_HOME)
        if action == 'Games Hub':
            self._open_games_hub_menu()
        elif action in ('Hub', 'Social Hub', 'Media Hub', 'Music Hub', 'Apps Hub', 'Settings Hub'):
            self._open_current_tab_menu()
        elif action == 'Open Tray':
            self._open_tray_dashboard_menu()
        elif action == 'My Pins':
            self._menu('My Pins', ['Casino', 'Runner', 'Gem Match', 'FNAE', 'Store', 'Web Browser', 'System Info', 'Web Control'])
        elif action == 'My Games':
            self._menu('My Games', ['Runner', 'Casino', 'Gem Match', 'FNAE', 'Steam', 'RetroArch', 'Games Integrations'])
        elif action in ('Browse Games', 'Browse'):
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_store.sh'])
        elif action in ('Search Games', 'Games Search'):
            q, ok = self._input_text('Search Games', 'Game or app:', '')
            if ok and str(q).strip():
                self._run('/bin/sh', ['-c', f'{xui}/bin/xui_store.sh'])
                self._msg('Search Games', f'Store opened. Use search: {str(q).strip()}')
        elif action in ('Games Marketplace', 'Games Market'):
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_store.sh'])
        elif action == 'Recently Played':
            try:
                arr = json.loads(RECENT_FILE.read_text()) if RECENT_FILE.exists() else []
            except Exception:
                arr = []
            recent_games = [x for x in arr if str(x) in (
                'Runner', 'Casino', 'Gem Match', 'FNAE', 'Steam', 'RetroArch', 'Lutris', 'Heroic', 'Store'
            )]
            self._menu('Recently Played', recent_games or ['No recent games'])
        elif action == 'Arcade Picks':
            self._menu('Arcade Picks', ['Gem Match', 'Runner', 'Casino', 'Missions'])
        elif action == 'Disc & Local Media':
            self._open_tray_dashboard_menu()
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
        elif action in ('Gem Match', 'Bejeweled'):
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_gem_match.sh'])
        elif action in ('FNAE', "Five Night's At Epstein's", "Five Nights At Epstein's"):
            run_fnae = f'{xui}/bin/xui_run_fnae.sh'
            install_fnae = f'{xui}/bin/xui_install_fnae.sh'
            installed = (
                subprocess.call(
                    ['/bin/sh', '-c', f'"{run_fnae}" --check'],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                ) == 0
            )
            if installed:
                self._run('/bin/sh', ['-c', f'"{run_fnae}"'])
            else:
                if self._ask_yes_no(
                    'FNAE',
                    'FNAE no esta instalado.\n\n'
                    'Se descargara desde MediaFire y se instalara ahora.\n'
                    'URL: https://www.mediafire.com/file/a4q4l09vdfqzzws/Five_Nights_At_Epsteins_Linux.tar/file\n\n'
                    'Deseas continuar?'
                ):
                    self._run_install_task(
                        'FNAE',
                        f'"{install_fnae}"',
                        success_msg='FNAE installed successfully.',
                        fail_msg='FNAE install failed. Check ~/.xui/logs/fnae_install.log',
                        launch_cmd=f'"{run_fnae}"',
                    )
        elif action == 'Uninstall FNAE':
            if self._ask_yes_no('FNAE', 'Uninstall Five Nights At Epstein\'s from local XUI apps folder?'):
                subprocess.getoutput('/bin/sh -c "rm -rf $HOME/.xui/apps/fnae $HOME/.xui/data/fnae_paths.json"')
                self._msg('FNAE', 'FNAE files removed from local install.')
        elif action == 'Steam':
            self._launch_platform('steam')
        elif action in ('Store', 'Avatar Store'):
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_store.sh'])
        elif action == 'Web Browser':
            self._run('/bin/sh', ['-c', f'{xui}/bin/xui_browser.sh --hub https://www.xbox.com'])
        elif action == 'Close Active App':
            out = subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_close_active_app.sh"')
            self._msg('Close Active App', out or 'No output')
        elif action in ('Missions', 'Misiones'):
            self._open_achievements_hub()
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
                'Gallery', 'Screenshot', 'Calculator', 'Gamepad Test', 'Controller Probe', 'Controller Mappings',
                'Controller L4T Fix', 'Controller Profile',
                'WiFi Toggle', 'Bluetooth Toggle',
                'Terminal', 'Process Monitor', 'Network Info', 'Disk Usage', 'Battery Info', 'Diagnostics',
                'HTTP Server', 'RetroArch', 'Torrent', 'Kodi', 'Screen Recorder', 'Clipboard Tool',
                'Emoji Picker', 'Cron Manager', 'Backup Data', 'Restore Last Backup', 'Plugin Manager',
                'Logs Viewer', 'JSON Browser', 'Archive Manager', 'Hash Tool', 'Ping Test',
                'Docker Status', 'VM Status', 'Open Notes', 'App Launcher', 'Service Manager',
                'Developer Tools', 'Scan Media Games', 'Install Wine Runtime', 'Games Integrations',
                'Web Browser', 'Virtual Keyboard', 'FNAE', 'Gem Match', 'Close Active App'
            ])
        elif action == 'Games Integrations':
            self._menu('Games Integrations', [
                'Platforms Status',
                'Steam', 'Install Steam',
                'RetroArch', 'Install RetroArch',
                'Lutris', 'Install Lutris',
                'Heroic', 'Install Heroic',
                'FNAE',
                'Gem Match',
                'Compat X86'
            ])
        elif action == 'Developer Tools':
            self._menu('Developer Tools', [
                'Terminal', 'Process Monitor', 'Logs Viewer', 'JSON Browser', 'Hash Tool',
                'Docker Status', 'VM Status', 'Network Info', 'Disk Usage', 'Diagnostics',
                'Gamepad Test', 'Controller Probe', 'Controller Mappings', 'Controller L4T Fix', 'Controller Profile'
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
            self._run_install_task(
                'Box64',
                f'"{xui}/bin/xui_install_box64.sh"',
                success_msg='Box64 install step completed.',
                fail_msg='Box64 install failed.',
            )
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
        elif action == 'Virtual Keyboard':
            d = VirtualKeyboardDialog('', self, sfx_cb=self._play_sfx)
            if d.exec_() == QtWidgets.QDialog.Accepted:
                txt = d.text()
                if txt:
                    qtxt = shlex.quote(txt)
                    subprocess.getoutput(f'/bin/sh -c "printf %s {qtxt} | xclip -selection clipboard 2>/dev/null || true"')
                    self._msg('Virtual Keyboard', f'Text captured ({len(txt)} chars) and copied to clipboard.')
                else:
                    self._msg('Virtual Keyboard', 'No text entered.')
        elif action == 'Scan Media Games':
            self._run_terminal(f'"{xui}/bin/xui_scan_media_games.sh"')
        elif action == 'Install Wine Runtime':
            self._run_install_task(
                'Wine Runtime',
                f'"{xui}/bin/xui_install_wine.sh"',
                success_msg='Wine runtime install step completed.',
                fail_msg='Wine runtime install failed.',
            )
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
        elif action == 'Controller Probe':
            self._run_terminal(f'"{xui}/bin/xui_controller_probe.sh"')
        elif action == 'Controller Mappings':
            out = subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_controller_mappings.sh"')
            self._msg('Controller Mappings', out or 'No mappings available.')
        elif action == 'Controller L4T Fix':
            self._run_terminal(f'"{xui}/bin/xui_controller_l4t_fix.sh"')
        elif action == 'Controller Profile':
            prof, ok = self._input_item('Controller Profile', 'Choose profile:', ['auto', 'xbox360', 'switch'], 0)
            if ok and prof:
                out = subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_controller_profile.sh {prof}"')
                self._msg('Controller Profile', out or f'Profile set: {prof}')
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
            payload = self._mandatory_update_payload()
            if isinstance(payload, dict) and bool(payload.get('checked', False)):
                if bool(payload.get('update_required', False)):
                    repo = str(payload.get('repo', 'afitler79-alt/XUI-X360-FRONTEND'))
                    rc = str(payload.get('remote_commit', 'unknown'))[:10]
                    if self._ask_yes_no('Update', f'Update required from {repo}\nLatest build: {rc}\n\nApply update now?'):
                        self._launch_mandatory_updater_and_quit()
                else:
                    self._msg('Update', 'System is up to date.')
            else:
                self._msg('Update', subprocess.getoutput(f'/bin/sh -c "{xui}/bin/xui_update_check.sh mandatory"'))
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

    def _dispatch_dashboard_key(self, key):
        target = self.focusWidget()
        if target is None:
            target = self
        for et in (QtCore.QEvent.KeyPress, QtCore.QEvent.KeyRelease):
            evt = QtGui.QKeyEvent(et, int(key), QtCore.Qt.NoModifier)
            QtWidgets.QApplication.sendEvent(target, evt)

    def _gp_emit(self, key, channel='main', repeat_sec=0.15):
        now = time.monotonic()
        last = float(self._gp_last_emit.get(channel, 0.0))
        if (now - last) < float(repeat_sec):
            return
        self._gp_last_emit[channel] = now
        self._dispatch_dashboard_key(key)

    def _gp_axis(self, axis_name, value):
        v = float(value)
        if abs(v) < 0.45:
            return
        if axis_name in ('lx', 'rx'):
            self._gp_emit(QtCore.Qt.Key_Left if v < 0 else QtCore.Qt.Key_Right, channel=f'axis_{axis_name}', repeat_sec=0.17)
        elif axis_name in ('ly', 'ry'):
            self._gp_emit(QtCore.Qt.Key_Up if v < 0 else QtCore.Qt.Key_Down, channel=f'axis_{axis_name}', repeat_sec=0.17)

    def _on_gp_connected_change(self, _device_id=None):
        if QtGamepad is None:
            return
        manager = QtGamepad.QGamepadManager.instance()
        active = set(manager.connectedGamepads())
        for did in list(self._qgamepads.keys()):
            if did not in active:
                gp = self._qgamepads.pop(did, None)
                if gp is not None:
                    gp.deleteLater()
        for did in sorted(active):
            if did in self._qgamepads:
                continue
            try:
                gp = QtGamepad.QGamepad(did, self)
            except Exception:
                continue
            self._qgamepads[did] = gp

            gp.buttonAChanged.connect(lambda p, did=did: p and self._gp_emit(QtCore.Qt.Key_Return, channel=f'{did}_a'))
            gp.buttonBChanged.connect(lambda p, did=did: p and self._gp_emit(QtCore.Qt.Key_Escape, channel=f'{did}_b'))
            gp.buttonXChanged.connect(lambda p, did=did: p and self._gp_emit(QtCore.Qt.Key_Space, channel=f'{did}_x'))
            gp.buttonYChanged.connect(lambda p, did=did: p and self._gp_emit(QtCore.Qt.Key_Tab, channel=f'{did}_y'))

            gp.buttonStartChanged.connect(lambda p, did=did: p and self._gp_emit(QtCore.Qt.Key_Return, channel=f'{did}_start'))
            gp.buttonSelectChanged.connect(lambda p, did=did: p and self._gp_emit(QtCore.Qt.Key_Escape, channel=f'{did}_back'))

            gp.buttonLeftShoulderChanged.connect(lambda p, did=did: p and self._gp_emit(QtCore.Qt.Key_Left, channel=f'{did}_lb'))
            gp.buttonRightShoulderChanged.connect(lambda p, did=did: p and self._gp_emit(QtCore.Qt.Key_Right, channel=f'{did}_rb'))
            gp.buttonL2Changed.connect(lambda v, did=did: v > 0.55 and self._gp_emit(QtCore.Qt.Key_Tab, channel=f'{did}_lt'))
            gp.buttonR2Changed.connect(lambda v, did=did: v > 0.55 and self._gp_emit(QtCore.Qt.Key_Tab, channel=f'{did}_rt'))

            gp.buttonUpChanged.connect(lambda p, did=did: p and self._gp_emit(QtCore.Qt.Key_Up, channel=f'{did}_du'))
            gp.buttonDownChanged.connect(lambda p, did=did: p and self._gp_emit(QtCore.Qt.Key_Down, channel=f'{did}_dd'))
            gp.buttonLeftChanged.connect(lambda p, did=did: p and self._gp_emit(QtCore.Qt.Key_Left, channel=f'{did}_dl'))
            gp.buttonRightChanged.connect(lambda p, did=did: p and self._gp_emit(QtCore.Qt.Key_Right, channel=f'{did}_dr'))

            if hasattr(gp, 'buttonGuideChanged'):
                gp.buttonGuideChanged.connect(lambda p, did=did: p and self._gp_emit(QtCore.Qt.Key_F1, channel=f'{did}_guide'))
            gp.buttonCenterChanged.connect(lambda p, did=did: p and self._gp_emit(QtCore.Qt.Key_F1, channel=f'{did}_center'))

            gp.axisLeftXChanged.connect(lambda v, did=did: self._gp_axis('lx', v))
            gp.axisLeftYChanged.connect(lambda v, did=did: self._gp_axis('ly', v))
            gp.axisRightXChanged.connect(lambda v, did=did: self._gp_axis('rx', v))
            gp.axisRightYChanged.connect(lambda v, did=did: self._gp_axis('ry', v))

    def _setup_qt_gamepad_input(self):
        if QtGamepad is None:
            return
        try:
            manager = QtGamepad.QGamepadManager.instance()
            manager.gamepadConnected.connect(self._on_gp_connected_change)
            manager.gamepadDisconnected.connect(self._on_gp_connected_change)
            self._on_gp_connected_change()
        except Exception:
            pass

    def keyPressEvent(self, e):
        k = e.key()
        if self._games_inline is not None and self._games_inline.isVisible():
            if k in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
                self._games_inline.close_overlay()
                return
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
        guide_keys = {QtCore.Qt.Key_F1, QtCore.Qt.Key_Home, QtCore.Qt.Key_Meta}
        key_super_l = getattr(QtCore.Qt, 'Key_Super_L', None)
        key_super_r = getattr(QtCore.Qt, 'Key_Super_R', None)
        if key_super_l is not None:
            guide_keys.add(key_super_l)
        if key_super_r is not None:
            guide_keys.add(key_super_r)
        if k in guide_keys:
            self._show_xbox_guide()
            return
        super().keyPressEvent(e)


def main():
    app = QtWidgets.QApplication(sys.argv)
    app.setApplicationName('XUI Xbox Style')
    f = app.font()
    scr = app.primaryScreen()
    if scr is not None:
        g = scr.availableGeometry()
        base_pt = 10 if (g.width() <= 1280 or g.height() <= 720) else 12
    else:
        base_pt = 12
    f.setPointSize(base_pt)
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
TARGET_HOME="${XUI_USER_HOME:-$HOME}"
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  if command -v getent >/dev/null 2>&1; then
    _su_home="$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)"
    [ -n "${_su_home:-}" ] && TARGET_HOME="$_su_home"
  elif [ -d "/home/$SUDO_USER" ]; then
    TARGET_HOME="/home/$SUDO_USER"
  fi
fi
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    if sudo -n "$0" "$@"; then
      exit 0
    fi
  fi
  echo "[WARN] Passwordless sudo is required. Install/update to write /etc/sudoers.d/xui-dashboard-\$USER." >&2
  exit 1
fi
export HOME="$TARGET_HOME"
export USER="${SUDO_USER:-${USER:-$(id -un)}}"
export LOGNAME="${SUDO_USER:-${LOGNAME:-$USER}}"
ASSETS_DIR="$TARGET_HOME/.xui/assets"
DASH_SCRIPT="$TARGET_HOME/.xui/dashboard/pyqt_dashboard_improved.py"
PY_RUNNER="$TARGET_HOME/.xui/bin/xui_python.sh"
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
X-GNOME-Autostart-enabled=false
Hidden=true
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
"""XUI controller bridge: Xbox and Joy-Con -> dashboard keyboard navigation."""
import logging
import os
import select
import shutil
import subprocess
import time

try:
    from evdev import InputDevice, ecodes, list_devices
except Exception as exc:
    print(f'evdev not available: {exc}')
    time.sleep(30)
    raise SystemExit(0)

LOG_FILE = os.path.expanduser('~/.xui/logs/joy_listener.log')
DEADZONE = int(os.environ.get('XUI_JOY_DEADZONE', '12000'))
REPEAT_SEC = float(os.environ.get('XUI_JOY_REPEAT_SEC', '0.22'))
RESCAN_SEC = float(os.environ.get('XUI_JOY_RESCAN_SEC', '2.5'))
GUIDE_COOLDOWN_SEC = float(os.environ.get('XUI_GUIDE_COOLDOWN_SEC', '0.85'))
NINTENDO_AB_SWAP = os.environ.get('XUI_JOY_NINTENDO_AB_SWAP', '1').lower() not in ('0', 'false', 'no')
JOY_PROFILE = os.environ.get('XUI_JOY_PROFILE', 'auto').strip().lower()
JOYCON_COMBINED_MODE = os.environ.get('XUI_JOY_SWITCH_COMBINED_MODE', 'auto').strip().lower()
if JOYCON_COMBINED_MODE not in ('auto', 'prefer-combined', 'split'):
    JOYCON_COMBINED_MODE = 'auto'
XDOTOOL = shutil.which('xdotool')
GUIDE_SCRIPT = os.path.expanduser('~/.xui/bin/xui_global_guide.sh')
ACTIVE_GAME_FILE = os.path.expanduser('~/.xui/data/active_game.pid')
NINTENDO_VENDOR = 0x057E
MICROSOFT_VENDOR = 0x045E
HYPERKIN_VENDOR = 0x2E24
JOYCON_LEFT_PRODUCTS = {0x2006}
JOYCON_RIGHT_PRODUCTS = {0x2007}
JOYCON_COMBINED_PRODUCTS = {0x200E, 0x2017}
NINTENDO_PRO_PRODUCTS = {0x2009}


def _default_display():
    if os.environ.get('DISPLAY'):
        return os.environ.get('DISPLAY')
    for idx in range(4):
        if os.path.exists(f'/tmp/.X11-unix/X{idx}'):
            return f':{idx}'
    return ':0'


os.environ.setdefault('DISPLAY', _default_display())


def _c(name, default):
    return getattr(ecodes, name, default)


FACE_BUTTON_CODES = {
    _c('BTN_SOUTH', 304), _c('BTN_EAST', 305), _c('BTN_NORTH', 307), _c('BTN_WEST', 308)
}
DPAD_BUTTON_CODES = {
    _c('BTN_DPAD_UP', 544), _c('BTN_DPAD_DOWN', 545), _c('BTN_DPAD_LEFT', 546), _c('BTN_DPAD_RIGHT', 547)
}
ANALOG_AXIS_CODES = {
    _c('ABS_X', 0), _c('ABS_Y', 1), _c('ABS_RX', 3), _c('ABS_RY', 4),
    _c('ABS_Z', 2), _c('ABS_RZ', 5),
}
HAT_CODES = {_c('ABS_HAT0X', 16), _c('ABS_HAT0Y', 17)}

COMMON_BUTTON_MAP = {
    _c('BTN_DPAD_UP', 544): 'Up',
    _c('BTN_DPAD_DOWN', 545): 'Down',
    _c('BTN_DPAD_LEFT', 546): 'Left',
    _c('BTN_DPAD_RIGHT', 547): 'Right',
    _c('BTN_START', 315): 'Return',
    _c('BTN_SELECT', 314): 'Escape',
    _c('BTN_MODE', 316): 'F1',
    _c('BTN_SOUTH', 304): 'Return',
    _c('BTN_EAST', 305): 'Escape',
    _c('BTN_NORTH', 307): 'space',
    _c('BTN_WEST', 308): 'Tab',
    _c('BTN_TL', 310): 'Tab',
    _c('BTN_TR', 311): 'Tab',
    _c('BTN_TL2', 312): 'Tab',
    _c('BTN_TR2', 313): 'Tab',
    _c('BTN_THUMBL', 317): 'F1',
    _c('BTN_THUMBR', 318): 'F1',
}
NINTENDO_BUTTON_MAP = {
    _c('BTN_EAST', 305): 'Return',
    _c('BTN_SOUTH', 304): 'Escape',
}
TRIGGER_HAPPY_MAP = {
    _c('BTN_TRIGGER_HAPPY1', 704): 'Left',
    _c('BTN_TRIGGER_HAPPY2', 705): 'Right',
    _c('BTN_TRIGGER_HAPPY3', 706): 'Up',
    _c('BTN_TRIGGER_HAPPY4', 707): 'Down',
}

XBOX_BUTTON_MAP = {
    _c('BTN_TL', 310): 'Left',
    _c('BTN_TR', 311): 'Right',
    _c('BTN_TL2', 312): 'Tab',
    _c('BTN_TR2', 313): 'Tab',
    _c('BTN_THUMBL', 317): 'F1',
    _c('BTN_THUMBR', 318): 'F1',
}

GUIDE_FALLBACK_CODES = {
    _c('BTN_MODE', 316),
    _c('KEY_HOMEPAGE', 172),
    _c('KEY_HOME', 102),
    _c('KEY_MENU', 139),
    _c('BTN_BASE', 294),
    _c('BTN_BASE2', 295),
    _c('BTN_BASE3', 296),
    _c('BTN_BASE4', 297),
}

JOYCON_LEFT_BUTTON_MAP = {
    _c('BTN_TL', 310): 'Tab',
    _c('BTN_TL2', 312): 'Escape',
    _c('BTN_START', 315): 'Return',
    _c('BTN_SELECT', 314): 'Escape',
    _c('BTN_MODE', 316): 'F1',
    _c('KEY_HOMEPAGE', 172): 'F1',
    _c('KEY_HOME', 102): 'F1',
    _c('KEY_MENU', 139): 'F1',
}

JOYCON_RIGHT_BUTTON_MAP = {
    _c('BTN_TR', 311): 'Right',
    _c('BTN_TR2', 313): 'Tab',
    _c('BTN_START', 315): 'Return',
    _c('BTN_SELECT', 314): 'Escape',
    _c('BTN_MODE', 316): 'F1',
    _c('KEY_HOMEPAGE', 172): 'F1',
    _c('KEY_HOME', 102): 'F1',
    _c('KEY_MENU', 139): 'F1',
}

JOYCON_COMBINED_BUTTON_MAP = {
    _c('BTN_TL', 310): 'Left',
    _c('BTN_TR', 311): 'Right',
    _c('BTN_TL2', 312): 'Tab',
    _c('BTN_TR2', 313): 'Tab',
    _c('BTN_START', 315): 'Return',
    _c('BTN_SELECT', 314): 'Escape',
    _c('BTN_MODE', 316): 'F1',
    _c('KEY_HOMEPAGE', 172): 'F1',
    _c('KEY_HOME', 102): 'F1',
    _c('KEY_MENU', 139): 'F1',
}

XBOX360_PROFILE_MAP = {
    _c('BTN_SOUTH', 304): 'Return',
    _c('BTN_EAST', 305): 'Escape',
    _c('BTN_NORTH', 307): 'space',
    _c('BTN_WEST', 308): 'Tab',
    _c('BTN_START', 315): 'Return',
    _c('BTN_SELECT', 314): 'Escape',
    _c('BTN_MODE', 316): 'F1',
    _c('KEY_HOMEPAGE', 172): 'F1',
    _c('KEY_HOME', 102): 'F1',
    _c('KEY_MENU', 139): 'F1',
    _c('BTN_TL', 310): 'Left',
    _c('BTN_TR', 311): 'Right',
    _c('BTN_TL2', 312): 'Tab',
    _c('BTN_TR2', 313): 'Tab',
}

SWITCH_PROFILE_MAP = {
    _c('BTN_EAST', 305): 'Return',
    _c('BTN_SOUTH', 304): 'Escape',
    _c('BTN_NORTH', 307): 'space',
    _c('BTN_WEST', 308): 'Tab',
    _c('KEY_HOMEPAGE', 172): 'F1',
    _c('KEY_HOME', 102): 'F1',
    _c('KEY_MENU', 139): 'F1',
}

ABS_MAP = {
    _c('ABS_X', 0): ('Left', 'Right'),
    _c('ABS_Y', 1): ('Up', 'Down'),
    _c('ABS_RX', 3): ('Left', 'Right'),
    _c('ABS_RY', 4): ('Up', 'Down'),
    _c('ABS_HAT0X', 16): ('Left', 'Right'),
    _c('ABS_HAT0Y', 17): ('Up', 'Down'),
}


def emit_key(key):
    if not XDOTOOL:
        return False
    try:
        r = subprocess.run(
            [XDOTOOL, 'key', '--clearmodifiers', str(key)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if int(getattr(r, 'returncode', 1) or 1) != 0:
            logging.warning('xdotool failed key=%s rc=%s display=%s', key, r.returncode, os.environ.get('DISPLAY', ''))
            return False
    except Exception as exc:
        logging.warning('xdotool exception for key=%s: %s', key, exc)
        return False
    return True


def _vendor_product(dev):
    info = getattr(dev, 'info', None)
    vendor = int(getattr(info, 'vendor', 0) or 0)
    product = int(getattr(info, 'product', 0) or 0)
    return vendor, product


def classify_controller(dev):
    name = (dev.name or '').lower()
    vendor, product = _vendor_product(dev)

    if vendor == NINTENDO_VENDOR:
        if product in JOYCON_LEFT_PRODUCTS or 'joy-con (l)' in name:
            return 'joycon_l'
        if product in JOYCON_RIGHT_PRODUCTS or 'joy-con (r)' in name:
            return 'joycon_r'
        if (
            product in JOYCON_COMBINED_PRODUCTS
            or 'combined joy-cons' in name
            or 'joy-cons (combined)' in name
            or 'joycon pair' in name
            or 'left+right joy-con' in name
            or 'left/right joy-con' in name
        ):
            return 'joycon_combined'
        if product in NINTENDO_PRO_PRODUCTS or 'pro controller' in name:
            return 'nintendo_pro'
        if 'nintendo switch' in name or 'joy-con' in name or 'joycon' in name:
            return 'nintendo'
        return 'nintendo'
    if vendor in (MICROSOFT_VENDOR, HYPERKIN_VENDOR):
        return 'xbox'

    if any(token in name for token in ('joy-con (l)', 'left joy-con', 'joycon l')):
        return 'joycon_l'
    if any(token in name for token in ('joy-con (r)', 'right joy-con', 'joycon r')):
        return 'joycon_r'
    if any(token in name for token in ('combined joy-cons', 'joy-cons (combined)', 'joycon pair', 'left+right joy-con', 'left/right joy-con')):
        return 'joycon_combined'
    if any(token in name for token in ('pro controller', 'nintendo switch pro')):
        return 'nintendo_pro'
    if any(token in name for token in ('joy-con', 'joycon', 'nintendo switch', 'switch')):
        return 'nintendo'
    if any(token in name for token in (
        'xbox', 'x-input', 'xinput', 'x-pad', 'xpadneo',
        'xenon', 'hyperkin', 'microsoft x-box', 'x-box one', 'xbox one'
    )):
        return 'xbox'
    return 'generic'


def is_controller_device(dev):
    name = (dev.name or '').lower()
    try:
        caps = dev.capabilities(absinfo=False)
    except Exception:
        return False
    key_caps = set(caps.get(ecodes.EV_KEY, []))
    abs_caps = set(caps.get(ecodes.EV_ABS, []))
    has_face = bool(key_caps & FACE_BUTTON_CODES)
    has_dpad = bool(key_caps & DPAD_BUTTON_CODES) or bool(abs_caps & HAT_CODES) or bool(key_caps & set(TRIGGER_HAPPY_MAP))
    has_axis = bool(abs_caps & ANALOG_AXIS_CODES)
    named_as_pad = any(token in name for token in (
        'xbox', 'x-input', 'xinput', 'x-pad', 'xenon', 'hyperkin',
        'joy-con', 'joycon', 'combined joy-cons', 'joy-cons (combined)',
        'nintendo switch', 'pro controller', 'hid-nintendo',
        'wireless controller', 'gamepad', 'joystick'
    ))
    if named_as_pad and (has_face or has_dpad or has_axis):
        return True
    if has_face and (has_axis or has_dpad):
        return True
    if has_face and len(key_caps) >= 8:
        return True
    return has_dpad and (has_axis or has_face)


def device_signature(dev):
    info = getattr(dev, 'info', None)
    bustype = int(getattr(info, 'bustype', 0) or 0)
    vendor = int(getattr(info, 'vendor', 0) or 0)
    product = int(getattr(info, 'product', 0) or 0)
    version = int(getattr(info, 'version', 0) or 0)
    phys = (getattr(dev, 'phys', '') or '').strip().lower()
    uniq = (getattr(dev, 'uniq', '') or '').strip().lower()
    name = (dev.name or '').strip().lower()
    return (phys, uniq, name, bustype, vendor, product, version)


def score_device(dev):
    try:
        caps = dev.capabilities(absinfo=False)
    except Exception:
        return 0
    key_caps = set(caps.get(ecodes.EV_KEY, []))
    abs_caps = set(caps.get(ecodes.EV_ABS, []))
    score = len(abs_caps) * 5 + len(key_caps)
    if key_caps & FACE_BUTTON_CODES:
        score += 30
    if key_caps & DPAD_BUTTON_CODES or abs_caps & HAT_CODES:
        score += 20
    if abs_caps & ANALOG_AXIS_CODES:
        score += 20
    return score


def _profile_overrides(kind):
    profile = JOY_PROFILE or 'auto'
    if profile in ('xbox360', 'xbox'):
        return dict(XBOX360_PROFILE_MAP)
    if profile in ('switch', 'nintendo'):
        if kind in ('nintendo', 'nintendo_pro', 'joycon_combined', 'joycon_l', 'joycon_r'):
            return dict(SWITCH_PROFILE_MAP)
    return {}


class ControllerBridge:
    def __init__(self):
        self.devices = {}
        self.device_kind = {}
        self.device_map = {}
        self.device_sig = {}
        self.axis_state = {}
        self.axis_last_emit = {}
        self.key_last_emit = {}
        self.suppressed_paths = set()
        self.last_suppressed_snapshot = ()
        self.last_guide_open = 0.0

    def _active_window_pid(self):
        if not XDOTOOL:
            return None
        try:
            wid = subprocess.check_output(
                [XDOTOOL, 'getactivewindow'],
                text=True,
                stderr=subprocess.DEVNULL
            ).strip()
            if not wid:
                return None
            pid_txt = subprocess.check_output(
                [XDOTOOL, 'getwindowpid', wid],
                text=True,
                stderr=subprocess.DEVNULL
            ).strip()
            if not pid_txt:
                return None
            pid = int(pid_txt)
            if pid <= 1:
                return None
            return pid
        except Exception:
            return None

    def _active_window_dashboard(self):
        if not XDOTOOL:
            return False
        try:
            pid = self._active_window_pid()
            if pid and self._is_dashboard_pid(pid):
                return True
            wid = subprocess.check_output(
                [XDOTOOL, 'getactivewindow'],
                text=True,
                stderr=subprocess.DEVNULL
            ).strip()
            if not wid:
                return False
            name = subprocess.check_output(
                [XDOTOOL, 'getwindowname', wid],
                text=True,
                stderr=subprocess.DEVNULL
            ).strip().lower()
            if any(t in name for t in ('xui', 'dashboard', 'xbox style')):
                return True
            return False
        except Exception:
            return False

    def _cmdline_of_pid(self, pid):
        try:
            return open(f'/proc/{int(pid)}/cmdline', 'rb').read().replace(b'\x00', b' ').decode('utf-8', 'ignore').lower()
        except Exception:
            return ''

    def _is_dashboard_pid(self, pid):
        cl = self._cmdline_of_pid(pid)
        return any(t in cl for t in ('pyqt_dashboard_improved.py', 'xui_startup_and_dashboard', 'xui-dashboard.service'))

    def _tracked_external_game_pid(self):
        if not os.path.exists(ACTIVE_GAME_FILE):
            return None
        pid = 0
        try:
            pid = int((open(ACTIVE_GAME_FILE, 'r', encoding='utf-8', errors='ignore').read() or '0').strip() or '0')
        except Exception:
            pid = 0
        if pid <= 1:
            try:
                os.remove(ACTIVE_GAME_FILE)
            except Exception:
                pass
            return None
        if not os.path.exists(f'/proc/{pid}'):
            try:
                os.remove(ACTIVE_GAME_FILE)
            except Exception:
                pass
            return None
        if self._is_dashboard_pid(pid):
            return None
        return pid

    def _active_external_window_pid(self):
        pid = self._active_window_pid()
        if pid is None:
            return None
        if not os.path.exists(f'/proc/{pid}'):
            return None
        if self._is_dashboard_pid(pid):
            return None
        return pid

    def _open_global_guide(self):
        now = time.monotonic()
        if (now - self.last_guide_open) < GUIDE_COOLDOWN_SEC:
            return True
        self.last_guide_open = now
        if self._active_window_dashboard():
            emit_key('F1')
            return True
        tracked_pid = self._tracked_external_game_pid()
        if tracked_pid is None:
            return False
        active_pid = self._active_external_window_pid()
        if active_pid is None or int(active_pid) != int(tracked_pid):
            return False
        if not os.path.exists(GUIDE_SCRIPT):
            return False
        try:
            subprocess.Popen(
                ['/bin/sh', '-lc', f'"{GUIDE_SCRIPT}"'],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
            return True
        except Exception:
            return False

    def _mapping_for_kind(self, kind):
        mapping = dict(COMMON_BUTTON_MAP)
        mapping.update(TRIGGER_HAPPY_MAP)
        if kind in ('nintendo', 'nintendo_pro', 'joycon_combined', 'joycon_l', 'joycon_r') and NINTENDO_AB_SWAP:
            mapping.update(NINTENDO_BUTTON_MAP)
        if kind == 'xbox':
            mapping.update(XBOX_BUTTON_MAP)
        elif kind == 'joycon_l':
            mapping.update(JOYCON_LEFT_BUTTON_MAP)
        elif kind == 'joycon_r':
            mapping.update(JOYCON_RIGHT_BUTTON_MAP)
        elif kind in ('joycon_combined', 'nintendo', 'nintendo_pro'):
            mapping.update(JOYCON_COMBINED_BUTTON_MAP)
        mapping.update(_profile_overrides(kind))
        return mapping

    def _refresh_joycon_combined_mode(self):
        left_paths = sorted([p for p, k in self.device_kind.items() if k == 'joycon_l'])
        right_paths = sorted([p for p, k in self.device_kind.items() if k == 'joycon_r'])
        combined_paths = sorted([p for p, k in self.device_kind.items() if k in ('joycon_combined',)])
        suppressed = set()
        mode = JOYCON_COMBINED_MODE

        if mode in ('auto', 'prefer-combined') and combined_paths:
            suppressed.update(left_paths)
            suppressed.update(right_paths)
        elif mode == 'split':
            suppressed = set()

        snapshot = tuple(sorted(suppressed))
        if snapshot != self.last_suppressed_snapshot:
            if suppressed:
                logging.info(
                    'joycon source mode=%s -> using combined (%s), suppressing split devices: %s',
                    mode,
                    ','.join(combined_paths) if combined_paths else '<none>',
                    ','.join(sorted(suppressed)),
                )
            else:
                if combined_paths:
                    logging.info('joycon source mode=%s -> split mode active; combined available=%s', mode, ','.join(combined_paths))
                elif left_paths or right_paths:
                    logging.info('joycon source mode=%s -> split mode (no virtual combined device)', mode)
            self.last_suppressed_snapshot = snapshot
        self.suppressed_paths = suppressed

    def _open_device(self, path):
        try:
            dev = InputDevice(path)
        except PermissionError as exc:
            logging.warning('permission denied opening %s: %s', path, exc)
            return None
        except Exception:
            return None
        if not is_controller_device(dev):
            return None
        try:
            dev.set_nonblocking(True)
        except Exception:
            pass
        return dev

    def scan(self):
        current = set(list_devices())
        known = set(self.devices.keys())
        for path in sorted(known - current):
            dev = self.devices.pop(path, None)
            if dev is not None:
                try:
                    dev.close()
                except Exception:
                    pass
                self.device_kind.pop(path, None)
                self.device_map.pop(path, None)
                self.device_sig.pop(path, None)
                logging.info('controller disconnected: %s', path)
        signature_paths = {}
        for path, sig in self.device_sig.items():
            signature_paths[sig] = path
        for path in sorted(current - known):
            dev = self._open_device(path)
            if dev is None:
                continue
            sig = device_signature(dev)
            kind = classify_controller(dev)
            prev_path = signature_paths.get(sig)
            if prev_path and prev_path in self.devices:
                prev_dev = self.devices.get(prev_path)
                keep_prev = False
                if prev_dev is not None:
                    keep_prev = score_device(prev_dev) >= score_device(dev)
                if keep_prev:
                    try:
                        dev.close()
                    except Exception:
                        pass
                    continue
                if prev_dev is not None:
                    try:
                        prev_dev.close()
                    except Exception:
                        pass
                self.devices.pop(prev_path, None)
                self.device_kind.pop(prev_path, None)
                self.device_map.pop(prev_path, None)
                self.device_sig.pop(prev_path, None)
            self.devices[path] = dev
            self.device_kind[path] = kind
            self.device_map[path] = self._mapping_for_kind(kind)
            self.device_sig[path] = sig
            signature_paths[sig] = path
            vendor, product = _vendor_product(dev)
            logging.info(
                'controller connected: %s (%s) kind=%s vid=0x%04x pid=0x%04x',
                path, dev.name, kind, vendor, product
            )
        self._refresh_joycon_combined_mode()
        active = set(self.devices.keys())
        self.axis_state = {k: v for k, v in self.axis_state.items() if k[0] in active}
        self.axis_last_emit = {k: v for k, v in self.axis_last_emit.items() if k[0] in active}
        self.key_last_emit = {k: v for k, v in self.key_last_emit.items() if k[0] in active}

    def _axis_direction(self, dev, code, value):
        if code in HAT_CODES:
            if value < 0:
                return -1
            if value > 0:
                return 1
            return 0
        try:
            info = dev.absinfo(code)
        except Exception:
            info = None
        if info is None:
            center = 0
            threshold = max(8000, DEADZONE)
        else:
            rng = max(1, int(info.max) - int(info.min))
            center = int(info.min) + (rng // 2)
            threshold = max(int(rng * 0.22), int(DEADZONE * (rng / 65535.0)), 8)
        delta = int(value) - int(center)
        if abs(delta) <= threshold:
            return 0
        return -1 if delta < 0 else 1

    def _handle_key(self, dev, ev):
        if dev.path in self.suppressed_paths:
            return
        if ev.value not in (1, 2):
            return
        if int(ev.code) in GUIDE_FALLBACK_CODES and ev.value == 1:
            if self._open_global_guide():
                return
        mapping = self.device_map.get(dev.path) or COMMON_BUTTON_MAP
        mapped = mapping.get(int(ev.code))
        if not mapped and int(ev.code) in GUIDE_FALLBACK_CODES:
            mapped = 'F1'
        if not mapped:
            return
        now = time.monotonic()
        key = (dev.path, int(ev.code))
        last = self.key_last_emit.get(key, 0.0)
        if ev.value == 2 and (now - last) < REPEAT_SEC:
            return
        if str(mapped).upper() == 'F1':
            if self._open_global_guide():
                return
        emit_key(mapped)
        self.key_last_emit[key] = now

    def _handle_abs(self, dev, ev):
        if dev.path in self.suppressed_paths:
            return
        pair = ABS_MAP.get(int(ev.code))
        if not pair:
            return
        direction = self._axis_direction(dev, int(ev.code), int(ev.value))
        akey = (dev.path, int(ev.code))
        prev = self.axis_state.get(akey, 0)
        now = time.monotonic()
        if direction == 0:
            self.axis_state[akey] = 0
            return
        last = self.axis_last_emit.get(akey, 0.0)
        if direction != prev or (now - last) >= REPEAT_SEC:
            emit_key(pair[0] if direction < 0 else pair[1])
            self.axis_last_emit[akey] = now
        self.axis_state[akey] = direction

    def poll(self):
        last_scan = 0.0
        while True:
            now = time.monotonic()
            if (now - last_scan) >= RESCAN_SEC:
                self.scan()
                last_scan = now
            active_devices = {p: d for p, d in self.devices.items() if p not in self.suppressed_paths}
            if not active_devices:
                time.sleep(0.35)
                continue
            fd_to_dev = {dev.fd: dev for dev in active_devices.values()}
            try:
                ready, _, _ = select.select(list(fd_to_dev.keys()), [], [], 0.35)
            except Exception:
                time.sleep(0.2)
                continue
            for fd in ready:
                dev = fd_to_dev.get(fd)
                if dev is None:
                    continue
                try:
                    for ev in dev.read():
                        if ev.type == ecodes.EV_KEY:
                            self._handle_key(dev, ev)
                        elif ev.type == ecodes.EV_ABS:
                            self._handle_abs(dev, ev)
                except OSError:
                    path = dev.path
                    try:
                        dev.close()
                    except Exception:
                        pass
                    self.devices.pop(path, None)
                    logging.info('controller read failed, removed: %s', path)
                except Exception:
                    continue

if __name__ == '__main__':
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    logging.basicConfig(
        filename=LOG_FILE,
        level=logging.INFO,
        format='%(asctime)s %(levelname)s %(message)s'
    )
    logging.info(
        'xui joy bridge starting (profile=%s, nintendo_ab_swap=%s, switch_combined_mode=%s)',
        JOY_PROFILE, NINTENDO_AB_SWAP, JOYCON_COMBINED_MODE
    )
    if os.environ.get('XDG_SESSION_TYPE', '').lower() == 'wayland':
        logging.warning('Wayland detected: xdotool key injection may fail; X11 session is recommended')
    logging.info('controller bridge display=%s', os.environ.get('DISPLAY', ''))
    if not XDOTOOL:
        logging.warning('xdotool not found, controller input cannot be injected')
    bridge = ControllerBridge()
    while True:
        try:
            bridge.poll()
        except KeyboardInterrupt:
            break
        except Exception as exc:
            logging.exception('joy bridge error: %s', exc)
            time.sleep(1.0)
PY
  chmod +x "$BIN_DIR/xui_joy_listener.py"

  cat > "$BIN_DIR/xui_controller_mappings.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
ENV_FILE="$HOME/.xui/data/controller_profile.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE" || true
fi
echo "Profile: ${XUI_JOY_PROFILE:-auto} | Nintendo AB swap: ${XUI_JOY_NINTENDO_AB_SWAP:-1} | Switch combined mode: ${XUI_JOY_SWITCH_COMBINED_MODE:-auto}"
echo
cat <<'TXT'
XUI Default Controller Mapping
------------------------------
Global:
  D-Pad / Stick -> Arrows
  South(A on Xbox / B on Nintendo) -> Enter
  East(B on Xbox / A on Nintendo with swap) -> Escape
  North(X) -> Space
  West(Y) -> Tab
  Start -> Enter
  Select/Back -> Escape
  Guide/Home/Mode -> F1 (Xbox Guide)

Xbox profile:
  LB -> Left
  RB -> Right
  LT -> Tab
  RT -> Tab
  L3/R3 -> F1

Joy-Con Left profile:
  L -> Tab
  ZL -> Escape
  Minus -> Escape
  Home/Capture/Mode -> F1

Joy-Con Right profile:
  R -> Right
  ZR -> Tab
  Plus -> Enter
  Home/Mode -> F1

Switch combined/acoplado:
  auto (default): usa mando virtual combinado cuando existe y evita eventos duplicados L/R
  prefer-combined: igual que auto, pero forzado a priorizar combinado
  split: usa L y R por separado siempre

Profiles:
  xui_controller_profile.sh auto
  xui_controller_profile.sh xbox360
  xui_controller_profile.sh switch
  xui_controller_profile.sh switch-split
TXT
BASH
  chmod +x "$BIN_DIR/xui_controller_mappings.sh"

  cat > "$BIN_DIR/xui_controller_probe.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
echo "=== XUI Controller Probe ==="
echo "Date: $(date)"
echo "DISPLAY=${DISPLAY:-<unset>}"
echo "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-<unset>}"
echo
if command -v xdotool >/dev/null 2>&1; then
  echo "[xdotool] OK ($(command -v xdotool))"
else
  echo "[xdotool] MISSING"
fi
echo
if [ -f "$HOME/.xui/data/controller_profile.env" ]; then
  echo "[profile env]"
  cat "$HOME/.xui/data/controller_profile.env"
  echo
fi
if command -v lsusb >/dev/null 2>&1; then
  echo "[USB devices - filtered]"
  lsusb | grep -Ei 'nintendo|xbox|microsoft|controller|gamepad|joy-con' || true
  echo
fi
if command -v python3 >/dev/null 2>&1; then
python3 - <<'PY'
try:
    from evdev import InputDevice, list_devices
except Exception as exc:
    print(f'evdev unavailable: {exc}')
    raise SystemExit(0)

print('[evdev controllers]')
paths = list_devices()
if not paths:
    print('No input devices found')
for p in paths:
    try:
        d = InputDevice(p)
    except PermissionError as exc:
        print(f'{p}: permission denied ({exc})')
        continue
    except Exception:
        continue
    name = (d.name or '').lower()
    if any(t in name for t in ('xbox','xenon','hyperkin','joy-con','joycon','combined joy-cons','nintendo','pro controller','gamepad','joystick','wireless controller')):
        info = getattr(d, 'info', None)
        vid = int(getattr(info, 'vendor', 0) or 0)
        pid = int(getattr(info, 'product', 0) or 0)
        print(f'{p}: {d.name} vid=0x{vid:04x} pid=0x{pid:04x}')
PY
else
  echo "python3 not found"
fi
echo
echo "[XUI joy listener log tail]"
tail -n 60 "$HOME/.xui/logs/joy_listener.log" 2>/dev/null || echo "No joy listener log yet."
echo
if command -v systemctl >/dev/null 2>&1; then
  echo "[xui-joy.service]"
  systemctl --user status xui-joy.service --no-pager -n 20 2>/dev/null || echo "xui-joy.service not running"
fi

echo
echo "[Qt input modules]"
python3 - <<'PY' 2>/dev/null || true
mods = ["PyQt5.QtGamepad", "PyQt5.QtCore"]
for m in mods:
    try:
        __import__(m)
        print(f"{m}: OK")
    except Exception as exc:
        print(f"{m}: FAIL ({exc})")
PY
BASH
  chmod +x "$BIN_DIR/xui_controller_probe.sh"

  cat > "$BIN_DIR/xui_controller_l4t_fix.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
as_root(){
  if [ "$(id -u)" -eq 0 ]; then "$@"; return $?; fi
  if [ "${XUI_NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
    if command -v pkexec >/dev/null 2>&1; then pkexec "$@"; return $?; fi
    if command -v sudo >/dev/null 2>&1; then sudo -n "$@"; return $?; fi
  else
    if command -v sudo >/dev/null 2>&1; then sudo "$@"; return $?; fi
    if command -v pkexec >/dev/null 2>&1; then pkexec "$@"; return $?; fi
  fi
  echo "root privileges unavailable for: $*" >&2
  return 1
}

echo "=== XUI L4T Controller Fix ==="
echo "Target: Kubuntu L4T / Switch (Joy-Con + Xbox pads)"
echo

if getent group input >/dev/null 2>&1; then
  if id -nG "$USER" | tr ' ' '\n' | grep -qx input; then
    echo "group input: user already included"
  else
    if as_root usermod -aG input "$USER" >/dev/null 2>&1; then
      echo "group input: added user '$USER' (logout/login required)"
    else
      echo "group input: could not add user '$USER'"
    fi
  fi
fi

for mod in joydev uinput hid_nintendo xpad; do
  if lsmod | awk '{print $1}' | grep -qx "$mod"; then
    echo "module $mod: already loaded"
  else
    if as_root modprobe "$mod" 2>/dev/null; then
      echo "module $mod: loaded"
    else
      echo "module $mod: not available"
    fi
  fi
done

if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files 2>/dev/null | grep -q '^joycond\.service'; then
    as_root systemctl enable --now joycond.service >/dev/null 2>&1 || true
    echo "joycond.service: enabled/started (best effort)"
  fi
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user restart xui-joy.service >/dev/null 2>&1 || true
  echo "xui-joy.service: restarted"
fi

echo
if [ -x "$HOME/.xui/bin/xui_controller_probe.sh" ]; then
  "$HOME/.xui/bin/xui_controller_probe.sh" || true
fi
echo
echo "Done. If buttons are inverted on Nintendo layout, toggle:"
echo "  export XUI_JOY_NINTENDO_AB_SWAP=1  # Nintendo A=Enter, B=Back"
echo "or"
echo "  export XUI_JOY_NINTENDO_AB_SWAP=0  # Keep physical labels"
echo "Switch combined/acoplado mode:"
echo "  export XUI_JOY_SWITCH_COMBINED_MODE=auto            # Recommended"
echo "  export XUI_JOY_SWITCH_COMBINED_MODE=prefer-combined # Force combined virtual pad if present"
echo "  export XUI_JOY_SWITCH_COMBINED_MODE=split           # Use L/R independently"
echo "Profile helper:"
echo "  ~/.xui/bin/xui_controller_profile.sh xbox360"
BASH
  chmod +x "$BIN_DIR/xui_controller_l4t_fix.sh"

  cat > "$BIN_DIR/xui_controller_profile.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
PROFILE="${1:-show}"
ENV_FILE="$HOME/.xui/data/controller_profile.env"
mkdir -p "$(dirname "$ENV_FILE")"

write_env(){
  local p="$1"
  local swap="$2"
  local combined_mode="$3"
  cat > "$ENV_FILE" <<EOF
XUI_JOY_PROFILE=$p
XUI_JOY_NINTENDO_AB_SWAP=$swap
XUI_JOY_SWITCH_COMBINED_MODE=$combined_mode
EOF
}

case "$PROFILE" in
  show)
    if [ -f "$ENV_FILE" ]; then
      cat "$ENV_FILE"
    else
      echo "XUI_JOY_PROFILE=auto"
      echo "XUI_JOY_NINTENDO_AB_SWAP=1"
      echo "XUI_JOY_SWITCH_COMBINED_MODE=auto"
    fi
    exit 0
    ;;
  auto|default)
    write_env auto 1 auto
    ;;
  xbox|xbox360)
    write_env xbox360 1 split
    ;;
  switch|nintendo)
    write_env switch 0 prefer-combined
    ;;
  switch-split|nintendo-split)
    write_env switch 0 split
    ;;
  *)
    echo "Usage: $0 {show|auto|xbox360|switch|switch-split}"
    exit 1
    ;;
esac

echo "Saved controller profile: $PROFILE"
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user restart xui-joy.service >/dev/null 2>&1 || true
  echo "xui-joy.service restarted"
fi
BASH
  chmod +x "$BIN_DIR/xui_controller_profile.sh"

  if [ ! -f "$DATA_DIR/controller_profile.env" ]; then
    cat > "$DATA_DIR/controller_profile.env" <<'EOF'
XUI_JOY_PROFILE=auto
XUI_JOY_NINTENDO_AB_SWAP=1
XUI_JOY_SWITCH_COMBINED_MODE=auto
EOF
  fi
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
import time
from pathlib import Path

DATA_HOME = Path.home() / '.xui' / 'data'
WALLET_FILE = DATA_HOME / 'saldo.json'
STORE_FILE = DATA_HOME / 'store.json'
MISSIONS_FILE = DATA_HOME / 'missions.json'
INVENTORY_FILE = DATA_HOME / 'inventory.json'
ACHIEVEMENTS_FILE = DATA_HOME / 'achievements.json'
ACHIEVEMENTS_MIN = 5000


def _safe_read(path, default):
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except Exception:
        return default


def _safe_write(path, data):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding='utf-8')


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


def _norm_key(text):
    raw = str(text or '').strip().lower()
    out = []
    last_sep = False
    for ch in raw:
        if ch.isalnum():
            out.append(ch)
            last_sep = False
        else:
            if not last_sep:
                out.append('_')
            last_sep = True
    key = ''.join(out).strip('_')
    while '__' in key:
        key = key.replace('__', '_')
    return key or 'unknown'


def _achievement(aid, title, desc, score=5, event='generic', value='', threshold=0):
    return {
        'id': str(aid),
        'title': str(title),
        'desc': str(desc),
        'score': int(max(1, score)),
        'event': str(event or 'generic'),
        'value': str(value or ''),
        'threshold': int(max(0, threshold)),
    }


def _action_seed():
    return [
        'Hub', 'Social Hub', 'Games Hub', 'Media Hub', 'Music Hub', 'Apps Hub', 'Settings Hub',
        'Open Tray', 'Rescan Media', 'Toggle Tray', 'Open Tray', 'Close Tray',
        'My Pins', 'Recent', 'Casino', 'Runner', 'Gem Match', 'FNAE', 'Steam', 'RetroArch',
        'Lutris', 'Heroic', 'Store', 'Avatar Store', 'Web Browser', 'Close Active App', 'Missions',
        'LAN', 'Messages', 'LAN Chat', 'LAN Status', 'P2P Internet Help', 'Party', 'Gamer Card',
        'Social Apps', 'Friends', 'Sign In', 'Utilities', 'Games Integrations', 'Developer Tools',
        'Service Manager', 'Service Status', 'Compat X86', 'Compatibility Status', 'Install Box64',
        'Install Steam', 'Install RetroArch', 'Install Lutris', 'Install Heroic', 'Platforms Status',
        'Game Details', 'Media Player', 'Boot Video', 'Netflix', 'YouTube', 'ESPN', 'Startup Sound',
        'All Audio Files', 'Playlist', 'Visualizer', 'System Music', 'Mute / Unmute',
        'System Info', 'Web Control', 'Web Start', 'Web Status', 'Web Stop', 'Theme Toggle',
        'Setup Wizard', 'File Manager', 'Gallery', 'Screenshot', 'Calculator', 'App Launcher',
        'Scan Media Games', 'Install Wine Runtime', 'Open Notes', 'Terminal', 'Process Monitor',
        'Network Info', 'Disk Usage', 'Battery Info', 'Diagnostics', 'HTTP Server', 'Torrent',
        'Kodi', 'Screen Recorder', 'Clipboard Tool', 'Logs Viewer', 'JSON Browser', 'Archive Manager',
        'Hash Tool', 'Ping Test', 'Docker Status', 'VM Status', 'Emoji Picker', 'Cron Manager',
        'Backup Data', 'Restore Last Backup', 'Plugin Manager', 'Restart Dashboard Service',
        'Gamepad Test', 'Controller Probe', 'Controller Mappings', 'Controller L4T Fix',
        'Controller Profile', 'WiFi Toggle', 'Bluetooth Toggle', 'Power Profile', 'Battery Saver',
        'Update Check', 'System Update', 'Family', 'Turn Off', 'Exit', 'Canjear codigo', 'Logros',
    ]


def _store_targets():
    data = load_store()
    raw_items = data.get('all_items', data.get('items', []))
    if not isinstance(raw_items, list):
        raw_items = []
    out = []
    seen = set()
    for raw in raw_items:
        if not isinstance(raw, dict):
            continue
        iid = str(raw.get('id', '')).strip()
        if not iid:
            continue
        key = _norm_key(iid)
        if key in seen:
            continue
        seen.add(key)
        out.append({
            'id': iid,
            'key': key,
            'name': str(raw.get('name', iid)).strip() or iid,
            'category': str(raw.get('category', 'Apps')).strip() or 'Apps',
        })
    return out


def _mission_targets():
    out = []
    seen = set()
    for raw in load_missions():
        if not isinstance(raw, dict):
            continue
        mid = str(raw.get('id', '')).strip() or str(raw.get('title', '')).strip()
        if not mid:
            continue
        key = _norm_key(mid)
        if key in seen:
            continue
        seen.add(key)
        out.append({
            'id': mid,
            'key': key,
            'title': str(raw.get('title', mid)).strip() or mid,
        })
    return out


def build_achievement_catalog(min_count=ACHIEVEMENTS_MIN):
    min_count = int(max(ACHIEVEMENTS_MIN, min_count))
    out = []

    # Global progression achievements.
    out.extend([
        _achievement('boot_001', 'System Warmup', 'Open the XUI dashboard for the first time.', 5, 'action_count', threshold=1),
        _achievement('boot_010', 'Live Ready', 'Perform ten dashboard actions.', 10, 'action_count', threshold=10),
        _achievement('launch_001', 'First Launch', 'Launch your first app or game.', 10, 'launch_count', threshold=1),
        _achievement('launch_050', 'Session Veteran', 'Launch fifty apps/games.', 35, 'launch_count', threshold=50),
        _achievement('store_001', 'First Purchase', 'Buy one item from the marketplace.', 10, 'purchase_count', threshold=1),
        _achievement('store_050', 'Collector', 'Own fifty marketplace items.', 45, 'purchase_count', threshold=50),
        _achievement('mission_001', 'Mission Start', 'Complete one mission.', 10, 'mission_count', threshold=1),
        _achievement('mission_020', 'Mission Commander', 'Complete twenty missions.', 60, 'mission_count', threshold=20),
    ])

    # One action achievement per dashboard action.
    seen_action = set()
    for idx, action in enumerate(_action_seed(), 1):
        key = _norm_key(action)
        if key in seen_action:
            continue
        seen_action.add(key)
        out.append(_achievement(
            f'action_{key}',
            f'{action} Used',
            f'Use action "{action}" from the dashboard.',
            4 + (idx % 12),
            'action',
            key,
            0
        ))

    # Per-item achievements (buy + launch) for store catalog.
    store_targets = _store_targets()
    for idx, item in enumerate(store_targets, 1):
        key = item['key']
        name = item['name']
        cat = item['category']
        out.append(_achievement(
            f'purchase_item_{key}',
            f'Owned: {name}',
            f'Buy "{name}" ({cat}) in marketplace.',
            6 + (idx % 15),
            'purchase',
            key,
            0
        ))
        out.append(_achievement(
            f'launch_item_{key}',
            f'Play: {name}',
            f'Launch "{name}" from dashboard/store.',
            8 + (idx % 18),
            'launch',
            key,
            0
        ))

    # Mission-specific achievements.
    for m in _mission_targets():
        out.append(_achievement(
            f'mission_{m["key"]}',
            f'Mission: {m["title"]}',
            f'Complete mission "{m["title"]}".',
            12,
            'mission',
            m['key'],
            0
        ))

    # Counter ladders.
    for n in (1, 3, 5, 10, 20, 35, 50, 75, 100, 150, 220, 300, 400, 520, 680, 820):
        out.append(_achievement(
            f'count_actions_{n:04d}',
            f'Action Chain {n}',
            f'Reach {n} dashboard actions.',
            5 + min(80, n // 8),
            'action_count',
            '',
            n
        ))
    for n in (1, 2, 3, 5, 8, 12, 20, 30, 45, 65, 90, 120, 180, 260, 360, 480):
        out.append(_achievement(
            f'count_launches_{n:04d}',
            f'Launcher Tier {n}',
            f'Launch {n} apps/games.',
            8 + min(90, n // 6),
            'launch_count',
            '',
            n
        ))
    for n in (1, 2, 3, 5, 8, 12, 20, 30, 45, 65, 90, 120, 180, 260):
        out.append(_achievement(
            f'count_purchases_{n:04d}',
            f'Buyer Tier {n}',
            f'Complete {n} marketplace purchases.',
            8 + min(90, n // 5),
            'purchase_count',
            '',
            n
        ))
    for n in (1, 2, 3, 5, 8, 12, 20, 30, 45, 60):
        out.append(_achievement(
            f'count_missions_{n:04d}',
            f'Mission Tier {n}',
            f'Complete {n} missions.',
            10 + min(100, n * 2),
            'mission_count',
            '',
            n
        ))

    # Ensure >600 achievements even on a minimal install.
    fill_idx = 1
    while len(out) < min_count:
        threshold = 10 + fill_idx
        out.append(_achievement(
            f'community_chain_{fill_idx:04d}',
            f'Community Chain {fill_idx:03d}',
            'Keep using apps and games across the dashboard ecosystem.',
            5 + (fill_idx % 16),
            'action_count',
            '',
            threshold
        ))
        fill_idx += 1

    # Deduplicate by ID while preserving order.
    dedup = []
    seen = set()
    for item in out:
        aid = str(item.get('id', '')).strip()
        if not aid or aid in seen:
            continue
        seen.add(aid)
        dedup.append(item)
    return dedup


def ensure_achievements(min_count=ACHIEVEMENTS_MIN):
    DATA_HOME.mkdir(parents=True, exist_ok=True)
    raw = _safe_read(ACHIEVEMENTS_FILE, {})
    if not isinstance(raw, dict):
        raw = {}
    catalog = build_achievement_catalog(min_count=min_count)
    catalog_ids = {str(x.get('id', '')) for x in catalog}

    unlocked = raw.get('unlocked', [])
    if not isinstance(unlocked, list):
        unlocked = []
    clean_unlocked = []
    seen_unlock = set()
    for rec in unlocked:
        if not isinstance(rec, dict):
            continue
        aid = str(rec.get('id', '')).strip()
        if not aid or aid in seen_unlock or aid not in catalog_ids:
            continue
        seen_unlock.add(aid)
        clean_unlocked.append({
            'id': aid,
            'ts': int(rec.get('ts', 0) or 0),
            'event': str(rec.get('event', '')),
            'value': str(rec.get('value', '')),
        })

    stats = raw.get('stats', {})
    if not isinstance(stats, dict):
        stats = {}
    state = {
        'version': 'xui-5000',
        'updated': int(time.time()),
        'items': catalog,
        'unlocked': clean_unlocked,
        'stats': {
            'actions': int(stats.get('actions', 0) or 0),
            'launches': int(stats.get('launches', 0) or 0),
            'purchases': int(stats.get('purchases', 0) or 0),
            'missions': int(stats.get('missions', 0) or 0),
        },
    }
    _safe_write(ACHIEVEMENTS_FILE, state)
    return state


def load_achievements():
    return ensure_achievements()


def achievements_progress():
    data = ensure_achievements()
    total = len(data.get('items', []))
    unlocked = len(data.get('unlocked', []))
    return {
        'total': total,
        'unlocked': unlocked,
        'locked': max(0, total - unlocked),
    }


def unlock_for_event(kind, value='', limit=6):
    state = ensure_achievements()
    kind = _norm_key(kind)
    val = _norm_key(value)

    stats = state.get('stats', {})
    if kind == 'action':
        stats['actions'] = int(stats.get('actions', 0)) + 1
    elif kind == 'launch':
        stats['launches'] = int(stats.get('launches', 0)) + 1
    elif kind == 'purchase':
        stats['purchases'] = int(stats.get('purchases', 0)) + 1
    elif kind == 'mission':
        stats['missions'] = int(stats.get('missions', 0)) + 1
    state['stats'] = stats

    catalog = state.get('items', [])
    catalog_map = {str(x.get('id', '')): x for x in catalog if isinstance(x, dict)}
    unlocked = state.get('unlocked', [])
    unlocked_ids = {str(x.get('id', '')) for x in unlocked if isinstance(x, dict)}

    candidates = []
    if kind == 'action':
        candidates.append(f'action_{val}')
    elif kind == 'launch':
        candidates.append(f'launch_{val}')
        candidates.append(f'launch_item_{val}')
    elif kind == 'purchase':
        candidates.append(f'purchase_{val}')
        candidates.append(f'purchase_item_{val}')
    elif kind == 'mission':
        candidates.append(f'mission_{val}')

    action_count = int(stats.get('actions', 0))
    launch_count = int(stats.get('launches', 0))
    purchase_count = int(stats.get('purchases', 0))
    mission_count = int(stats.get('missions', 0))

    for item in catalog:
        if not isinstance(item, dict):
            continue
        aid = str(item.get('id', '')).strip()
        if not aid:
            continue
        ev = _norm_key(item.get('event', 'generic'))
        ev_val = _norm_key(item.get('value', ''))
        thr = int(item.get('threshold', 0) or 0)
        if ev == kind and ev_val and ev_val == val:
            candidates.append(aid)
            continue
        if ev == 'action_count' and action_count >= thr > 0:
            candidates.append(aid)
            continue
        if ev == 'launch_count' and launch_count >= thr > 0:
            candidates.append(aid)
            continue
        if ev == 'purchase_count' and purchase_count >= thr > 0:
            candidates.append(aid)
            continue
        if ev == 'mission_count' and mission_count >= thr > 0:
            candidates.append(aid)
            continue

    fresh = []
    seen = set()
    now = int(time.time())
    max_unlock = int(max(1, limit))
    for aid in candidates:
        aid = str(aid).strip()
        if not aid or aid in seen:
            continue
        seen.add(aid)
        if aid in unlocked_ids:
            continue
        item = catalog_map.get(aid)
        if not item:
            continue
        unlocked.append({'id': aid, 'ts': now, 'event': kind, 'value': val})
        unlocked_ids.add(aid)
        fresh.append({
            'id': aid,
            'title': str(item.get('title', aid)),
            'desc': str(item.get('desc', '')),
            'score': int(item.get('score', 0) or 0),
            'event': kind,
            'value': val,
            'ts': now,
        })
        if len(fresh) >= max_unlock:
            break

    state['unlocked'] = unlocked
    state['updated'] = int(time.time())
    _safe_write(ACHIEVEMENTS_FILE, state)
    return fresh


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
        return {'completed': False, 'reward': 0.0, 'balance': get_balance(), 'achievements': []}
    if missions[idx].get('done'):
        return {'completed': False, 'reward': 0.0, 'balance': get_balance(), 'achievements': []}
    reward = float(missions[idx].get('reward', 0))
    mid = str(missions[idx].get('id', '')).strip() or str(mission_id or title_contains or '')
    missions[idx]['done'] = True
    save_missions(missions)
    if reward > 0:
        change_balance(reward)
    fresh = unlock_for_event('mission', mid, limit=4)
    return {'completed': True, 'reward': reward, 'balance': get_balance(), 'achievements': fresh}
PY
  chmod +x "$BIN_DIR/xui_game_lib.py"

  cat > "$CASINO_DIR/casino.py" <<'PY'
#!/usr/bin/env python3
import json
import queue
import random
import sys
import threading
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from PyQt5 import QtCore, QtGui, QtWidgets

sys.path.insert(0, str(Path.home() / '.xui' / 'bin'))
from xui_game_lib import get_balance, change_balance, ensure_wallet, complete_mission, unlock_for_event


RED_NUMBERS = {1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36}


def _load_gamertag():
    prof = Path.home() / '.xui' / 'data' / 'profile.json'
    try:
        data = json.loads(prof.read_text(encoding='utf-8', errors='ignore'))
        name = str(data.get('gamertag', 'Player1')).strip()
        return name or 'Player1'
    except Exception:
        return 'Player1'


class CasinoOnlineRelay:
    def __init__(self, nickname):
        self.nickname = str(nickname or 'Player1')
        self.node_id = uuid.uuid4().hex[:12]
        self.relay = str(
            Path.home().joinpath('.xui').joinpath('data').as_posix()
        )  # placeholder; replaced below
        self.relay = str(
            __import__('os').environ.get('XUI_WORLD_RELAY_URL', 'https://ntfy.sh')
        ).strip().rstrip('/')
        self.topic = self._sanitize_topic(
            __import__('os').environ.get('XUI_CASINO_TOPIC', 'xui-casino-global')
        )
        self.enabled = True
        self.events = queue.Queue()
        self.running = False
        self._thread = None
        self._seen_ids = set()

    def _sanitize_topic(self, text):
        raw = ''.join(ch.lower() if ch.isalnum() or ch in ('-', '_', '.') else '-' for ch in str(text or '').strip())
        while '--' in raw:
            raw = raw.replace('--', '-')
        raw = raw.strip('-._')
        return raw or 'xui-casino-global'

    def _topic_url(self, suffix=''):
        topic = urllib.parse.quote(self.topic, safe='')
        return f'{self.relay}/{topic}{suffix}'

    def start(self):
        if self.running:
            return
        self.running = True
        self._thread = threading.Thread(target=self._recv_loop, daemon=True)
        self._thread.start()
        self.events.put(('status', f'Online relay connected: {self.topic}'))

    def stop(self):
        self.running = False
        if self._thread is not None:
            self._thread.join(timeout=0.2)

    def set_enabled(self, enabled):
        self.enabled = bool(enabled)
        if self.enabled:
            self.events.put(('status', f'Online relay enabled: {self.topic}'))
        else:
            self.events.put(('status', 'Online relay disabled'))

    def send_roll(self, room, game, roll, stake):
        payload = {
            'kind': 'xui_casino_roll',
            'node_id': self.node_id,
            'from': self.nickname,
            'room': str(room or 'global'),
            'game': str(game or 'dice_duel'),
            'roll': int(roll),
            'stake': int(stake),
            'ts': float(time.time()),
        }
        req = urllib.request.Request(
            self._topic_url(''),
            data=json.dumps(payload, ensure_ascii=False).encode('utf-8', errors='ignore'),
            method='POST',
            headers={
                'Content-Type': 'text/plain; charset=utf-8',
                'User-Agent': 'xui-casino-online',
                'X-Title': f'XUI-Casino:{self.nickname}',
            },
        )
        with urllib.request.urlopen(req, timeout=8) as r:
            _ = r.read(128)

    def _recv_loop(self):
        backoff = 1.2
        while self.running:
            if not self.enabled:
                time.sleep(0.4)
                continue
            req = urllib.request.Request(
                self._topic_url('/json'),
                headers={
                    'User-Agent': 'xui-casino-online',
                    'Cache-Control': 'no-cache',
                    'Connection': 'keep-alive',
                },
            )
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    backoff = 1.2
                    while self.running and self.enabled:
                        raw = resp.readline()
                        if not raw:
                            break
                        line = raw.decode('utf-8', errors='ignore').strip()
                        if not line:
                            continue
                        try:
                            evt = json.loads(line)
                        except Exception:
                            continue
                        if str(evt.get('event') or '') != 'message':
                            continue
                        msg_id = str(evt.get('id') or '')
                        if msg_id:
                            if msg_id in self._seen_ids:
                                continue
                            self._seen_ids.add(msg_id)
                            if len(self._seen_ids) > 1200:
                                self._seen_ids = set(list(self._seen_ids)[-600:])
                        body = str(evt.get('message') or '').strip()
                        if not body:
                            continue
                        try:
                            payload = json.loads(body)
                        except Exception:
                            continue
                        if str(payload.get('kind') or '') != 'xui_casino_roll':
                            continue
                        if str(payload.get('node_id') or '') == self.node_id:
                            continue
                        self.events.put(('roll', payload))
            except Exception as exc:
                self.events.put(('status', f'Online relay reconnecting: {exc}'))
                time.sleep(min(8.0, backoff))
                backoff = min(8.0, backoff * 1.5)


class CasinoWindow(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()
        self.nickname = _load_gamertag()
        ensure_wallet()
        unlock_for_event('launch', 'casino', limit=2)
        self.start_msg = f'Bienvenido al casino, {self.nickname}.'
        m = complete_mission(mission_id='m1')
        if m.get('completed'):
            self.start_msg = f"Bienvenido al casino. Mission +EUR {m.get('reward', 0):.2f}"
        self._slots_timer = QtCore.QTimer(self)
        self._slots_timer.timeout.connect(self._slots_tick)
        self._slots_pending = None
        self._slots_ticks = 0
        self._slots_target = ['7', 'BAR', 'CHERRY']
        self._roulette_timer = QtCore.QTimer(self)
        self._roulette_timer.timeout.connect(self._roulette_tick)
        self._roulette_pending = None
        self._roulette_ticks = 0
        self._roulette_target = 0
        self._coin_timer = QtCore.QTimer(self)
        self._coin_timer.timeout.connect(self._coin_tick)
        self._coin_pending = None
        self._coin_ticks = 0
        self._coin_target = 'HEADS'
        self._bj_timer = QtCore.QTimer(self)
        self._bj_timer.timeout.connect(self._blackjack_tick)
        self._bj_steps = []
        self._bj_step_idx = 0
        self.hilo_card = random.randint(1, 13)
        self.online_room = 'global'
        self.online_rolls = []
        self.online_points = {}
        self.relay = CasinoOnlineRelay(self.nickname)
        self.relay.start()
        self.online_timer = QtCore.QTimer(self)
        self.online_timer.timeout.connect(self._poll_online_events)
        self.online_timer.start(160)
        self.setWindowTitle('XUI Casino')
        self.resize(1220, 760)
        self._build()
        self.refresh_balance(self.start_msg)
        self._update_hilo_card()

    def _build(self):
        root = QtWidgets.QWidget()
        self.setCentralWidget(root)
        v = QtWidgets.QVBoxLayout(root)
        v.setContentsMargins(16, 16, 16, 16)
        v.setSpacing(12)

        self.balance_lbl = QtWidgets.QLabel()
        self.balance_lbl.setStyleSheet('font-size:28px; font-weight:700; color:#d8ffd8;')
        self.info_lbl = QtWidgets.QLabel()
        self.info_lbl.setStyleSheet('font-size:20px; color:#f0f7f0;')
        v.addWidget(self.balance_lbl)
        v.addWidget(self.info_lbl)

        tabs = QtWidgets.QTabWidget()
        tabs.addTab(self._slots_tab(), 'Slots')
        tabs.addTab(self._roulette_tab(), 'Roulette')
        tabs.addTab(self._blackjack_tab(), 'Blackjack')
        tabs.addTab(self._hilo_tab(), 'Hi-Lo')
        tabs.addTab(self._coin_tab(), 'Coin Flip')
        tabs.addTab(self._online_tab(), 'Dice Duel Online')
        v.addWidget(tabs, 1)

        self.setStyleSheet('''
            QMainWindow {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #122318, stop:1 #0a1510);
                color:#eef7ee;
            }
            QTabWidget::pane { border:1px solid #2a4738; background:#0f1a15; }
            QTabBar::tab { background:#1e3529; color:#e9f5e9; padding:10px 18px; font-size:16px; }
            QTabBar::tab:selected { background:#2f9f49; color:#ffffff; font-weight:700; }
            QPushButton { background:#2ea84a; color:white; border:none; padding:8px 14px; border-radius:4px; }
            QPushButton:hover { background:#37bc55; }
            QSpinBox, QComboBox { background:#1d2a23; color:white; border:1px solid #3b5244; padding:4px; }
            QLabel#result { font-size:30px; font-weight:700; color:#f8fff8; }
            QListWidget {
                background:#09130f;
                border:1px solid #2d4e3d;
                color:#e8f6e8;
                font-size:15px;
            }
            QLineEdit {
                background:#142119;
                border:1px solid #355b46;
                color:#f2fbf2;
                padding:6px;
                font-size:15px;
                font-weight:700;
            }
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
        spin_btn = QtWidgets.QPushButton('Spin (Animated)')
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
        if self._slots_timer.isActive():
            self.refresh_balance('Slots animation in progress...')
            return
        bet = int(self.slots_bet.value())
        bal = get_balance()
        if bet <= 0 or bet > bal:
            self.refresh_balance('Apuesta inválida para el balance actual.')
            return
        symbols = ['7', 'BAR', 'CHERRY', 'BELL', 'X']
        self._slots_pending = bet
        self._slots_target = [random.choice(symbols) for _ in range(3)]
        self._slots_ticks = 0
        self._slots_timer.start(75)
        self.refresh_balance('Slots spinning...')

    def _slots_tick(self):
        symbols = ['7', 'BAR', 'CHERRY', 'BELL', 'X']
        self._slots_ticks += 1
        reels = [random.choice(symbols), random.choice(symbols), random.choice(symbols)]
        self.slots_result.setText(' | '.join(reels))
        if self._slots_ticks % 2 == 0:
            self.slots_result.setStyleSheet('font-size:34px; font-weight:800; color:#e8ffe8;')
        else:
            self.slots_result.setStyleSheet('font-size:34px; font-weight:800; color:#8cffaf;')
        if self._slots_ticks < 18:
            return
        self._slots_timer.stop()
        bet = int(self._slots_pending or 0)
        reels = list(self._slots_target)
        self.slots_result.setText(' | '.join(reels))
        self.slots_result.setStyleSheet('font-size:36px; font-weight:900; color:#ffffff;')
        payout = 0
        if reels[0] == reels[1] == reels[2]:
            payout = bet * (12 if reels[0] == '7' else 6)
        elif len(set(reels)) == 2:
            payout = bet * 2
        delta = -bet + payout
        new_bal = change_balance(delta)
        if payout > 0:
            self.refresh_balance(f'Slots: +EUR {payout:.2f} (neto {delta:+.2f})')
            unlock_for_event('win', 'casino_slots', limit=2)
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
        play_btn = QtWidgets.QPushButton('Spin Roulette (Animated)')
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
        if self._roulette_timer.isActive():
            self.refresh_balance('Roulette spin in progress...')
            return
        bet = int(self.roulette_bet.value())
        bal = get_balance()
        if bet <= 0 or bet > bal:
            self.refresh_balance('Apuesta inválida para roulette.')
            return
        self._roulette_pending = {
            'bet': bet,
            'mode': self.roulette_mode.currentText(),
            'exact': int(self.roulette_number.value()),
        }
        self._roulette_target = random.randint(0, 36)
        self._roulette_ticks = 0
        self._roulette_timer.start(70)
        self.refresh_balance('Roulette spinning...')

    def _roulette_tick(self):
        self._roulette_ticks += 1
        n = random.randint(0, 36)
        color = 'Green' if n == 0 else ('Red' if n in RED_NUMBERS else 'Black')
        tone = '#96ff8e' if self._roulette_ticks % 2 else '#f0fff0'
        self.roulette_result.setStyleSheet(f'font-size:30px; font-weight:900; color:{tone};')
        self.roulette_result.setText(f'Spinning: {n} ({color})')
        if self._roulette_ticks < 22:
            return
        self._roulette_timer.stop()
        pend = dict(self._roulette_pending or {})
        bet = int(pend.get('bet') or 0)
        mode = str(pend.get('mode') or 'Red')
        exact = int(pend.get('exact') or 0)
        result = int(self._roulette_target)
        color = 'Green' if result == 0 else ('Red' if result in RED_NUMBERS else 'Black')
        payout = 0
        mode = self.roulette_mode.currentText()

        if mode == 'Exact':
            if result == exact:
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
        self.roulette_result.setStyleSheet('font-size:32px; font-weight:900; color:#ffffff;')
        self.roulette_result.setText(f'Resultado: {result} ({color})')
        if payout > 0:
            self.refresh_balance(f'Roulette: +EUR {payout:.2f} (neto {delta:+.2f})')
            unlock_for_event('win', 'casino_roulette', limit=2)
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
        btn = QtWidgets.QPushButton('Play Hand (Animated Deal)')
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
        if self._bj_timer.isActive():
            self.refresh_balance('Blackjack deal in progress...')
            return
        bet = int(self.bj_bet.value())
        bal = get_balance()
        if bet <= 0 or bet > bal:
            self.refresh_balance('Apuesta inválida para blackjack.')
            return
        p1 = random.randint(2, 11)
        p2 = random.randint(2, 11)
        d1 = random.randint(2, 11)
        d2 = random.randint(2, 11)
        player = p1 + p2 + random.randint(0, 9)
        dealer = d1 + d2 + random.randint(0, 9)
        self._bj_steps = [
            f'Player deals {p1}, Dealer deals {d1}',
            f'Player draws {p2}, Dealer draws hidden',
            f'Player total now ~ {p1 + p2}, Dealer showing {d1}',
            f'Final hand -> Player {player} | Dealer {dealer}',
        ]
        self._bj_step_idx = 0
        self._bj_pending = {'bet': bet, 'player': player, 'dealer': dealer}
        self._bj_timer.start(260)
        self.refresh_balance('Blackjack dealing...')

    def _blackjack_tick(self):
        if self._bj_step_idx < len(self._bj_steps):
            self.bj_result.setText(self._bj_steps[self._bj_step_idx])
            self._bj_step_idx += 1
            return
        self._bj_timer.stop()
        bet = int(self._bj_pending.get('bet') or 0)
        player = int(self._bj_pending.get('player') or 0)
        dealer = int(self._bj_pending.get('dealer') or 0)
        payout = 0
        msg = 'Push'
        if player > 21:
            msg = 'Te pasaste'
        elif dealer > 21 or player > dealer:
            msg = 'Ganaste'
            payout = bet * 2
        elif dealer == player:
            msg = 'Push'
            payout = bet
        else:
            msg = 'Perdiste'
        delta = -bet + payout
        new_bal = change_balance(delta)
        self.bj_result.setText(f'Player: {player} | Dealer: {dealer} -> {msg}')
        self.refresh_balance(f'Blackjack neto: {delta:+.2f}')
        if payout > bet:
            unlock_for_event('win', 'casino_blackjack', limit=2)
        self.balance_lbl.setText(f'Balance: EUR {new_bal:.2f}')

    def _hilo_tab(self):
        w = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(w)
        v.setContentsMargins(16, 16, 16, 16)
        v.setSpacing(10)
        self.hilo_card_lbl = QtWidgets.QLabel('Current card: ?')
        self.hilo_card_lbl.setObjectName('result')
        self.hilo_card_lbl.setAlignment(QtCore.Qt.AlignCenter)
        row = QtWidgets.QHBoxLayout()
        self.hilo_bet = QtWidgets.QSpinBox()
        self.hilo_bet.setRange(1, 1000)
        self.hilo_bet.setValue(12)
        self.hilo_high = QtWidgets.QPushButton('Higher')
        self.hilo_low = QtWidgets.QPushButton('Lower')
        self.hilo_high.clicked.connect(lambda: self.play_hilo('high'))
        self.hilo_low.clicked.connect(lambda: self.play_hilo('low'))
        row.addWidget(QtWidgets.QLabel('Bet:'))
        row.addWidget(self.hilo_bet)
        row.addWidget(self.hilo_high)
        row.addWidget(self.hilo_low)
        row.addStretch(1)
        hint = QtWidgets.QLabel('Adivina si la siguiente carta sera mayor o menor. Acierto x2, empate push.')
        hint.setStyleSheet('font-size:16px; color:#d4e9d4;')
        v.addWidget(self.hilo_card_lbl)
        v.addLayout(row)
        v.addWidget(hint)
        v.addStretch(1)
        return w

    def _update_hilo_card(self):
        names = {1: 'A', 11: 'J', 12: 'Q', 13: 'K'}
        text = names.get(int(self.hilo_card), str(int(self.hilo_card)))
        self.hilo_card_lbl.setText(f'Current card: {text}')

    def play_hilo(self, guess):
        bet = int(self.hilo_bet.value())
        bal = get_balance()
        if bet <= 0 or bet > bal:
            self.refresh_balance('Apuesta inválida para Hi-Lo.')
            return
        prev = int(self.hilo_card)
        nxt = random.randint(1, 13)
        self.hilo_card = nxt
        self._update_hilo_card()
        payout = 0
        if nxt == prev:
            payout = bet
            msg = f'Empate ({prev}->{nxt}), push.'
        elif (guess == 'high' and nxt > prev) or (guess == 'low' and nxt < prev):
            payout = bet * 2
            msg = f'Acierto ({prev}->{nxt}), ganaste.'
        else:
            msg = f'Fallaste ({prev}->{nxt}).'
        delta = -bet + payout
        new_bal = change_balance(delta)
        self.refresh_balance(f'Hi-Lo: {msg} Neto {delta:+.2f}')
        if payout > bet:
            unlock_for_event('win', 'casino_hilo', limit=2)
        self.balance_lbl.setText(f'Balance: EUR {new_bal:.2f}')

    def _coin_tab(self):
        w = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(w)
        v.setContentsMargins(16, 16, 16, 16)
        v.setSpacing(10)
        self.coin_face_lbl = QtWidgets.QLabel('Coin: HEADS')
        self.coin_face_lbl.setObjectName('result')
        self.coin_face_lbl.setAlignment(QtCore.Qt.AlignCenter)
        row = QtWidgets.QHBoxLayout()
        self.coin_bet = QtWidgets.QSpinBox()
        self.coin_bet.setRange(1, 1000)
        self.coin_bet.setValue(10)
        self.coin_pick = QtWidgets.QComboBox()
        self.coin_pick.addItems(['HEADS', 'TAILS'])
        self.coin_btn = QtWidgets.QPushButton('Flip Coin (Animated)')
        self.coin_btn.clicked.connect(self.play_coin)
        row.addWidget(QtWidgets.QLabel('Bet:'))
        row.addWidget(self.coin_bet)
        row.addWidget(QtWidgets.QLabel('Pick:'))
        row.addWidget(self.coin_pick)
        row.addWidget(self.coin_btn)
        row.addStretch(1)
        hint = QtWidgets.QLabel('Acierto x2, fallo pierde apuesta.')
        hint.setStyleSheet('font-size:16px; color:#d4e9d4;')
        v.addWidget(self.coin_face_lbl)
        v.addLayout(row)
        v.addWidget(hint)
        v.addStretch(1)
        return w

    def play_coin(self):
        if self._coin_timer.isActive():
            self.refresh_balance('Coin animation in progress...')
            return
        bet = int(self.coin_bet.value())
        bal = get_balance()
        if bet <= 0 or bet > bal:
            self.refresh_balance('Apuesta inválida para Coin Flip.')
            return
        self._coin_pending = {'bet': bet, 'pick': str(self.coin_pick.currentText()).strip().upper()}
        self._coin_target = random.choice(['HEADS', 'TAILS'])
        self._coin_ticks = 0
        self._coin_timer.start(90)
        self.refresh_balance('Coin flipping...')

    def _coin_tick(self):
        self._coin_ticks += 1
        side = 'HEADS' if self._coin_ticks % 2 == 0 else 'TAILS'
        self.coin_face_lbl.setText(f'Coin: {side}')
        if self._coin_ticks < 16:
            return
        self._coin_timer.stop()
        self.coin_face_lbl.setText(f'Coin: {self._coin_target}')
        bet = int(self._coin_pending.get('bet') or 0)
        pick = str(self._coin_pending.get('pick') or 'HEADS')
        payout = bet * 2 if pick == self._coin_target else 0
        delta = -bet + payout
        new_bal = change_balance(delta)
        if payout > 0:
            self.refresh_balance(f'Coin Flip win: +EUR {payout:.2f} (neto {delta:+.2f})')
            unlock_for_event('win', 'casino_coin', limit=2)
        else:
            self.refresh_balance(f'Coin Flip lose: -EUR {bet:.2f}')
        self.balance_lbl.setText(f'Balance: EUR {new_bal:.2f}')

    def _online_tab(self):
        w = QtWidgets.QWidget()
        root = QtWidgets.QVBoxLayout(w)
        root.setContentsMargins(16, 16, 16, 16)
        root.setSpacing(10)

        row1 = QtWidgets.QHBoxLayout()
        self.online_room_edit = QtWidgets.QLineEdit(self.online_room)
        self.online_room_edit.setPlaceholderText('Room name')
        btn_set_room = QtWidgets.QPushButton('Set Room')
        self.online_toggle = QtWidgets.QPushButton('Online: ON')
        btn_set_room.clicked.connect(self._set_online_room)
        self.online_toggle.clicked.connect(self._toggle_online)
        row1.addWidget(QtWidgets.QLabel('Room:'))
        row1.addWidget(self.online_room_edit, 1)
        row1.addWidget(btn_set_room)
        row1.addWidget(self.online_toggle)

        row2 = QtWidgets.QHBoxLayout()
        self.online_bet = QtWidgets.QSpinBox()
        self.online_bet.setRange(1, 1000)
        self.online_bet.setValue(20)
        self.online_roll_btn = QtWidgets.QPushButton('Roll Online')
        self.online_roll_btn.clicked.connect(self.play_online_dice)
        self.online_last_lbl = QtWidgets.QLabel('Your roll: -')
        self.online_last_lbl.setStyleSheet('font-size:20px; font-weight:800; color:#d5ffd5;')
        row2.addWidget(QtWidgets.QLabel('Stake:'))
        row2.addWidget(self.online_bet)
        row2.addWidget(self.online_roll_btn)
        row2.addStretch(1)
        row2.addWidget(self.online_last_lbl)

        body = QtWidgets.QHBoxLayout()
        self.online_feed = QtWidgets.QListWidget()
        self.online_board = QtWidgets.QListWidget()
        self.online_feed.setMinimumWidth(640)
        self.online_board.setMinimumWidth(300)
        body.addWidget(self.online_feed, 2)
        body.addWidget(self.online_board, 1)

        self.online_status = QtWidgets.QLabel('Online duel compares your roll against room median from real players.')
        self.online_status.setStyleSheet('font-size:16px; color:#d4e9d4;')

        root.addLayout(row1)
        root.addLayout(row2)
        root.addLayout(body, 1)
        root.addWidget(self.online_status)
        return w

    def _set_online_room(self):
        room = str(self.online_room_edit.text() or '').strip().lower()
        if not room:
            room = 'global'
        if len(room) > 60:
            room = room[:60]
        self.online_room = ''.join(ch if ch.isalnum() or ch in ('-', '_', '.') else '-' for ch in room)
        self.online_room_edit.setText(self.online_room)
        self.online_status.setText(f'Online room set: {self.online_room}')
        self._refresh_online_board()

    def _toggle_online(self):
        self.relay.set_enabled(not self.relay.enabled)
        if self.relay.enabled:
            self.online_toggle.setText('Online: ON')
            self.online_status.setText(f'Online enabled on topic {self.relay.topic}')
        else:
            self.online_toggle.setText('Online: OFF')
            self.online_status.setText('Online disabled')

    def _record_roll(self, payload, local=False):
        item = {
            'from': str(payload.get('from') or 'Unknown'),
            'room': str(payload.get('room') or 'global'),
            'roll': int(payload.get('roll') or 0),
            'stake': int(payload.get('stake') or 0),
            'game': str(payload.get('game') or 'dice_duel'),
            'ts': float(payload.get('ts') or time.time()),
            'local': bool(local),
        }
        self.online_rolls.append(item)
        if len(self.online_rolls) > 700:
            self.online_rolls = self.online_rolls[-500:]
        if item['room'] == self.online_room:
            stamp = time.strftime('%H:%M:%S', time.localtime(item['ts']))
            prefix = 'YOU' if local else item['from']
            self.online_feed.insertItem(0, f"[{stamp}] {prefix} rolled {item['roll']} (stake {item['stake']})")
            while self.online_feed.count() > 90:
                self.online_feed.takeItem(self.online_feed.count() - 1)
        self._refresh_online_board()

    def _refresh_online_board(self):
        now = time.time()
        room_events = [
            e for e in self.online_rolls
            if str(e.get('room')) == self.online_room and (now - float(e.get('ts', 0))) <= 1800.0
        ]
        stats = {}
        for e in room_events:
            who = str(e.get('from') or 'Unknown')
            data = stats.setdefault(who, {'sum': 0.0, 'n': 0, 'high': 0})
            roll = int(e.get('roll') or 0)
            data['sum'] += float(roll)
            data['n'] += 1
            data['high'] = max(int(data['high']), roll)
        ranking = []
        for who, d in stats.items():
            avg = float(d['sum']) / max(1, int(d['n']))
            ranking.append((avg, int(d['high']), int(d['n']), who))
        ranking.sort(key=lambda x: (-x[0], -x[1], -x[2], x[3].lower()))
        self.online_board.clear()
        if not ranking:
            self.online_board.addItem('No online players yet in this room.')
            return
        for i, (avg, high, n, who) in enumerate(ranking[:14], 1):
            self.online_board.addItem(f'{i:02d}. {who} | AVG {avg:.1f} | HIGH {high} | ROUNDS {n}')

    def play_online_dice(self):
        if not self.relay.enabled:
            self.refresh_balance('Online mode is disabled.')
            return
        stake = int(self.online_bet.value())
        bal = get_balance()
        if stake <= 0 or stake > bal:
            self.refresh_balance('Stake invalid for online duel.')
            return
        room = str(self.online_room or 'global')
        now = time.time()
        opponent_rolls = [
            int(e.get('roll') or 0)
            for e in self.online_rolls
            if str(e.get('room')) == room
            and str(e.get('from')) != self.nickname
            and (now - float(e.get('ts', 0))) <= 900.0
        ]
        roll = random.randint(1, 100)
        payout = 0
        if len(opponent_rolls) < 2:
            # Not enough opponents: no loss, no gain.
            delta = 0
            self.online_status.setText('Not enough online opponents yet. Stake refunded.')
        else:
            med = sorted(opponent_rolls)[len(opponent_rolls) // 2]
            if roll > med:
                payout = int(round(stake * 2.2))
            elif roll == med:
                payout = stake
            delta = -stake + payout
            self.online_status.setText(f'Opponent median: {med} | Your roll: {roll}')
        new_bal = change_balance(delta)
        self.balance_lbl.setText(f'Balance: EUR {new_bal:.2f}')
        self.online_last_lbl.setText(f'Your roll: {roll}')
        if delta > 0:
            self.refresh_balance(f'Online duel win! Neto {delta:+.2f}')
            unlock_for_event('social', 'casino_online_win', limit=2)
        elif delta < 0:
            self.refresh_balance(f'Online duel lose. Neto {delta:+.2f}')
        else:
            self.refresh_balance('Online duel push/refund.')
        payload = {
            'from': self.nickname,
            'room': room,
            'game': 'dice_duel',
            'roll': int(roll),
            'stake': int(stake),
            'ts': float(now),
        }
        self._record_roll(payload, local=True)
        try:
            self.relay.send_roll(room, 'dice_duel', int(roll), int(stake))
        except Exception as exc:
            self.online_status.setText(f'Online send failed: {exc}')

    def _poll_online_events(self):
        while True:
            try:
                evt = self.relay.events.get_nowait()
            except queue.Empty:
                break
            kind = evt[0]
            if kind == 'status':
                self.online_status.setText(str(evt[1]))
                continue
            if kind == 'roll':
                payload = dict(evt[1] or {})
                self._record_roll(payload, local=False)

    def keyPressEvent(self, e):
        if e.key() in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.close()
            return
        super().keyPressEvent(e)

    def closeEvent(self, e):
        for t in (self._slots_timer, self._roulette_timer, self._coin_timer, self._bj_timer, self.online_timer):
            try:
                t.stop()
            except Exception:
                pass
        try:
            self.relay.stop()
        except Exception:
            pass
        super().closeEvent(e)


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
from xui_game_lib import change_balance, get_balance, complete_mission, unlock_for_event


class RunnerGame(QtWidgets.QWidget):
    def __init__(self):
        super().__init__()
        unlock_for_event('launch', 'runner', limit=2)
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
from PyQt5 import QtCore, QtWidgets

sys.path.insert(0, str(Path.home() / '.xui' / 'bin'))
from xui_game_lib import load_missions, save_missions, get_balance, complete_mission


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
        res = complete_mission(mission_id=mission.get('id'))
        reward = float(res.get('reward', 0))
        bal = float(res.get('balance', get_balance()))
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
import json
import random
import shlex
import shutil
import subprocess
import sys
import time
from datetime import date
from pathlib import Path
from PyQt5 import QtCore, QtGui, QtWidgets
try:
    from PyQt5 import QtGamepad
except Exception:
    QtGamepad = None

sys.path.insert(0, str(Path.home() / '.xui' / 'bin'))
from xui_game_lib import (
    load_store, load_inventory, save_inventory, get_balance, change_balance, complete_mission,
    unlock_for_event, ensure_achievements,
)

DATA_HOME = Path.home() / '.xui' / 'data'
STORE_FILE = DATA_HOME / 'store.json'
XUI_BIN = Path.home() / '.xui' / 'bin'
COVER_CACHE = Path.home() / '.xui' / 'cache' / 'store_covers'
EXTERNAL_STORE_FILE = DATA_HOME / 'store_external.json'
EXTERNAL_STALE_SECONDS = 6 * 60 * 60
DAILY_ACTIVE_COUNT = 360
ALWAYS_VISIBLE_IDS = {
    'game_fnae_fangame',
    'minigame_bejeweled_xui',
    'game_casino',
    'game_runner',
    'browser_xui_webhub',
    'platform_steam',
    'platform_retroarch',
}


def _safe_write(path, data):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding='utf-8')


def _norm_item(raw):
    it = dict(raw or {})
    iid = str(it.get('id', '')).strip()
    if not iid:
        return None
    name = str(it.get('name', iid)).strip() or iid
    try:
        price = float(it.get('price', 0))
    except Exception:
        price = 0.0
    it['id'] = iid
    it['name'] = name
    it['price'] = round(max(0.0, price), 2)
    it['desc'] = str(it.get('desc', '')).strip()
    it['category'] = str(it.get('category', 'Apps')).strip() or 'Apps'
    it['source'] = str(it.get('source', 'XUI')).strip() or 'XUI'
    it['launch'] = str(it.get('launch', '')).strip()
    it['install'] = str(it.get('install', '')).strip()
    it['cover'] = str(it.get('cover', '')).strip()
    it['cover_local'] = str(it.get('cover_local', '')).strip()
    pricing = str(it.get('pricing', '')).strip().lower()
    if pricing not in ('free', 'paid'):
        pricing = 'paid' if float(it['price']) > 0 else 'free'
    it['pricing'] = pricing
    it['purchase_url'] = str(it.get('purchase_url', '')).strip()
    it['external_checkout'] = bool(
        bool(it.get('external_checkout', False))
        or (it['pricing'] == 'paid' and bool(it['purchase_url']))
    )
    return it


def _curated_items():
    return [
        {
            'id': 'browser_xui_webhub',
            'name': 'XUI Web Browser',
            'price': 0,
            'category': 'Browser',
            'source': 'XUI',
            'desc': 'Custom Chromium-based browser with Xbox style web hub.',
            'launch': str(XUI_BIN / 'xui_browser.sh') + ' --hub https://www.xbox.com',
        },
        {
            'id': 'game_fnae_fangame',
            'name': "Five Night's At Epstein's",
            'price': 85,
            'category': 'Games',
            'source': 'XUI',
            'desc': 'Fangame package with Linux/Windows detection and launcher.',
            'install': str(XUI_BIN / 'xui_install_fnae.sh'),
            'launch': str(XUI_BIN / 'xui_run_fnae.sh'),
        },
        {
            'id': 'minigame_bejeweled_xui',
            'name': 'Bejeweled XUI (Gem Match)',
            'price': 20,
            'category': 'MiniGames',
            'desc': 'Match-3 style minigame integrated in dashboard.',
            'launch': str(XUI_BIN / 'xui_gem_match.sh'),
        },
        {
            'id': 'game_casino',
            'name': 'Casino',
            'price': 0,
            'category': 'Games',
            'desc': 'Casino minigame.',
            'launch': str(XUI_BIN / 'xui_python.sh') + ' ' + str(Path.home() / '.xui' / 'casino' / 'casino.py'),
        },
        {
            'id': 'game_runner',
            'name': 'Runner',
            'price': 0,
            'category': 'MiniGames',
            'desc': 'Runner arcade minigame.',
            'launch': str(XUI_BIN / 'xui_python.sh') + ' ' + str(Path.home() / '.xui' / 'games' / 'runner.py'),
        },
        {
            'id': 'game_missions',
            'name': 'Missions',
            'price': 0,
            'category': 'Apps',
            'desc': 'Mission and rewards panel.',
            'launch': str(XUI_BIN / 'xui_missions.sh'),
        },
        {
            'id': 'platform_steam',
            'name': 'Steam Integration',
            'price': 10,
            'category': 'Apps',
            'source': 'XUI',
            'desc': 'Launch and integrate Steam.',
            'install': str(XUI_BIN / 'xui_install_steam.sh'),
            'launch': str(XUI_BIN / 'xui_steam.sh'),
        },
        {
            'id': 'platform_retroarch',
            'name': 'RetroArch Integration',
            'price': 10,
            'category': 'Apps',
            'source': 'XUI',
            'desc': 'Install and launch RetroArch.',
            'install': str(XUI_BIN / 'xui_install_retroarch.sh'),
            'launch': str(XUI_BIN / 'xui_retroarch.sh'),
        },
        {
            'id': 'platform_lutris',
            'name': 'Lutris Integration',
            'price': 10,
            'category': 'Apps',
            'source': 'XUI',
            'desc': 'Install and launch Lutris.',
            'install': str(XUI_BIN / 'xui_install_lutris.sh'),
            'launch': str(XUI_BIN / 'xui_lutris.sh'),
        },
        {
            'id': 'platform_heroic',
            'name': 'Heroic Integration',
            'price': 10,
            'category': 'Apps',
            'source': 'XUI',
            'desc': 'Install and launch Heroic Games Launcher.',
            'install': str(XUI_BIN / 'xui_install_heroic.sh'),
            'launch': str(XUI_BIN / 'xui_heroic.sh'),
        },
        {
            'id': 'platform_itch',
            'name': 'Itch.io App',
            'price': 0,
            'category': 'Apps',
            'source': 'Itch.io',
            'desc': 'Install and launch the Itch desktop app (Flathub).',
            'install': str(XUI_BIN / 'xui_install_itch.sh'),
            'launch': str(XUI_BIN / 'xui_itch.sh'),
        },
        {
            'id': 'platform_gamejolt',
            'name': 'Game Jolt Hub',
            'price': 0,
            'category': 'Browser',
            'source': 'Game Jolt',
            'desc': 'Browse Game Jolt titles inside XUI browser hub.',
            'launch': str(XUI_BIN / 'xui_browser.sh') + ' --hub https://gamejolt.com/games',
        },
        {
            'id': 'hub_legal_steam_free',
            'name': 'Steam Free-to-Play Hub',
            'price': 0,
            'category': 'Games',
            'desc': 'Browse legal free-to-play titles from Steam.',
            'launch': str(XUI_BIN / 'xui_browser.sh') + ' --hub https://store.steampowered.com/genre/Free%20to%20Play/',
        },
        {
            'id': 'hub_legal_itch',
            'name': 'Itch.io Free Games Hub',
            'price': 0,
            'category': 'Games',
            'desc': 'Browse legal indie free games on itch.io.',
            'launch': str(XUI_BIN / 'xui_browser.sh') + ' --hub https://itch.io/games/free',
        },
        {
            'id': 'hub_legal_flathub_games',
            'name': 'Flathub Games Hub',
            'price': 0,
            'category': 'Games',
            'desc': 'Discover legal open-source games and apps on Flathub.',
            'launch': str(XUI_BIN / 'xui_browser.sh') + ' --hub https://flathub.org/apps/collection/popular/1',
        },
        {
            'id': 'hub_legal_moddb_games',
            'name': 'ModDB Games Hub',
            'price': 0,
            'category': 'Games',
            'source': 'ModDB',
            'desc': 'Discover PC and indie games from ModDB.',
            'launch': str(XUI_BIN / 'xui_browser.sh') + ' --hub https://www.moddb.com/games',
        },
        {
            'id': 'real_openra_moddb',
            'name': 'OpenRA (ModDB)',
            'price': 0,
            'category': 'Games',
            'source': 'ModDB',
            'desc': 'Real-time strategy game page on ModDB.',
            'launch': str(XUI_BIN / 'xui_browser.sh') + ' --hub https://www.moddb.com/games/openra',
        },
        {
            'id': 'real_holocure_itch',
            'name': 'HoloCure (Itch.io)',
            'price': 0,
            'category': 'Games',
            'source': 'Itch.io',
            'desc': 'Real game page on Itch.io.',
            'launch': str(XUI_BIN / 'xui_browser.sh') + ' --hub https://kay-yu.itch.io/holocure',
        },
        {
            'id': 'real_fnaf_gamejolt',
            'name': 'FNAF Fan Games (Game Jolt)',
            'price': 0,
            'category': 'Games',
            'source': 'Game Jolt',
            'desc': 'Real Game Jolt catalog filtered for FNAF fan games.',
            'launch': str(XUI_BIN / 'xui_browser.sh') + ' --hub https://gamejolt.com/games?tags=fnaf',
        },
        {
            'id': 'hub_paid_itch',
            'name': 'Itch.io Paid Games Hub',
            'price': 0,
            'pricing': 'paid',
            'external_checkout': True,
            'purchase_url': 'https://itch.io/games/price-paid',
            'category': 'Games',
            'source': 'Itch.io',
            'desc': 'Browse paid games on Itch.io. Purchase happens on official Itch pages.',
            'launch': str(XUI_BIN / 'xui_browser.sh') + ' --hub https://itch.io/games/price-paid',
        },
        {
            'id': 'hub_paid_gamejolt_market',
            'name': 'Game Jolt Marketplace',
            'price': 0,
            'pricing': 'paid',
            'external_checkout': True,
            'purchase_url': 'https://gamejolt.com/marketplace',
            'category': 'Games',
            'source': 'Game Jolt',
            'desc': 'Paid creator content and products on Game Jolt official marketplace.',
            'launch': str(XUI_BIN / 'xui_browser.sh') + ' --hub https://gamejolt.com/marketplace',
        },
        {
            'id': 'hub_paid_steam',
            'name': 'Steam Paid Games Hub',
            'price': 0,
            'pricing': 'paid',
            'external_checkout': True,
            'purchase_url': 'https://store.steampowered.com/search/?maxprice=70',
            'category': 'Games',
            'source': 'Steam',
            'desc': 'Paid games on Steam store. Purchase is completed on official Steam pages.',
            'launch': str(XUI_BIN / 'xui_browser.sh') + ' --hub https://store.steampowered.com/search/?maxprice=70',
        },
        {
            'id': 'hub_paid_gog',
            'name': 'GOG Paid Games Hub',
            'price': 0,
            'pricing': 'paid',
            'external_checkout': True,
            'purchase_url': 'https://www.gog.com/en/games',
            'category': 'Games',
            'source': 'GOG',
            'desc': 'Paid PC games catalog on GOG official store.',
            'launch': str(XUI_BIN / 'xui_browser.sh') + ' --hub https://www.gog.com/en/games',
        },
    ]

def _rotation_key():
    return date.today().isoformat()


def _stable_seed(text):
    seed = 0
    for b in str(text).encode('utf-8', errors='ignore'):
        seed = ((seed * 131) + int(b)) & 0xFFFFFFFF
    return seed


def _daily_rotated_items(all_items, keep_ids=None, active_count=DAILY_ACTIVE_COUNT):
    keep_ids = set(keep_ids or [])
    day_key = _rotation_key()
    keep = []
    pool = []
    external_priority = []
    for item in all_items:
        iid = str(item.get('id', '')).strip()
        src = str(item.get('source', 'XUI')).strip().lower()
        cat = str(item.get('category', 'Apps')).strip().lower()
        if iid and iid in keep_ids:
            keep.append(item)
        elif src in ('flathub', 'itch.io', 'game jolt', 'moddb') and cat in ('games', 'minigames'):
            external_priority.append(item)
        else:
            pool.append(item)
    # Keep a visible slice of external catalog every day.
    ext_keep = external_priority[:140]
    keep_ids2 = {str(x.get('id', '')).strip() for x in keep}
    for x in ext_keep:
        xid = str(x.get('id', '')).strip()
        if xid and xid not in keep_ids2:
            keep.append(x)
            keep_ids2.add(xid)
    rnd = random.Random(_stable_seed(day_key))
    rnd.shuffle(pool)
    target = max(int(active_count), len(keep))
    take = max(0, target - len(keep))
    active = keep + pool[:take]
    return active, day_key


def _load_external_items():
    try:
        data = json.loads(EXTERNAL_STORE_FILE.read_text(encoding='utf-8', errors='ignore'))
        items = data.get('items', [])
        return items if isinstance(items, list) else []
    except Exception:
        return []


def _maybe_background_sync_external():
    script = XUI_BIN / 'xui_store_sync_sources.sh'
    if not script.exists():
        return
    try:
        stale = True
        if EXTERNAL_STORE_FILE.exists():
            age = max(0.0, time.time() - EXTERNAL_STORE_FILE.stat().st_mtime)
            stale = age > EXTERNAL_STALE_SECONDS
        if stale:
            subprocess.Popen(['/bin/sh', '-lc', str(script)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def ensure_catalog_minimum(min_count=620):
    _maybe_background_sync_external()
    data = load_store()
    if not isinstance(data, dict):
        data = {}
    raw_items = data.get('all_items', data.get('items', []))
    if not isinstance(raw_items, list):
        raw_items = []
    items = []
    seen = set()
    for raw in raw_items:
        item = _norm_item(raw)
        if item is None:
            continue
        iid = item['id']
        if iid.startswith('auto_') or iid.startswith('itch_page_') or iid.startswith('gamejolt_page_'):
            continue
        if iid in seen:
            continue
        seen.add(iid)
        items.append(item)
    for raw in _curated_items():
        item = _norm_item(raw)
        if item is None:
            continue
        if item['id'] in seen:
            continue
        seen.add(item['id'])
        items.append(item)
    for raw in _load_external_items():
        item = _norm_item(raw)
        if item is None:
            continue
        if item['id'].startswith('itch_page_') or item['id'].startswith('gamejolt_page_'):
            continue
        if item['id'] in seen:
            continue
        seen.add(item['id'])
        items.append(item)
    active_items, day_key = _daily_rotated_items(items, ALWAYS_VISIBLE_IDS, DAILY_ACTIVE_COUNT)
    out = {
        'catalog_version': 'xui-real-sources',
        'rotation_day': day_key,
        'rotation_active_count': len(active_items),
        'rotation_total_count': len(items),
        'all_items': items,
        'items': active_items,
    }
    _safe_write(STORE_FILE, out)
    return out


class StoreTile(QtWidgets.QFrame):
    clicked = QtCore.pyqtSignal(object)

    def __init__(self, item, owned=False):
        super().__init__()
        self.item = dict(item or {})
        self.owned = bool(owned)
        self.selected = False
        self.setObjectName('store_tile')
        self.setCursor(QtCore.Qt.PointingHandCursor)
        self.setFixedSize(248, 188)
        self._build()
        self._apply_style()

    def _tile_colors(self):
        seed = _stable_seed(str(self.item.get('id', '')))
        h1 = seed % 360
        h2 = (h1 + 26) % 360
        c1 = QtGui.QColor.fromHsv(h1, 165, 180).name()
        c2 = QtGui.QColor.fromHsv(h2, 190, 122).name()
        return c1, c2

    def _short_desc(self, text, limit=52):
        txt = str(text or '').strip()
        if len(txt) <= limit:
            return txt
        return txt[: max(0, limit - 3)] + '...'

    def _price_text(self):
        price = float(self.item.get('price', 0))
        pricing = str(self.item.get('pricing', 'free')).strip().lower()
        external_paid = bool(self.item.get('external_checkout', False))
        if pricing == 'paid' and external_paid:
            return 'PAID'
        if pricing == 'free' or price <= 0:
            return 'FREE'
        return f'EUR {price:.2f}'

    def _build(self):
        c1, c2 = self._tile_colors()
        root = QtWidgets.QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        self.hero = QtWidgets.QLabel(str(self.item.get('category', 'Apps')).upper())
        self.hero.setObjectName('tile_hero')
        self.hero.setAlignment(QtCore.Qt.AlignLeft | QtCore.Qt.AlignTop)
        self.hero.setMargin(10)
        self.hero.setMinimumHeight(122)
        self.hero.setStyleSheet(
            'QLabel#tile_hero {'
            f'background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 {c1}, stop:1 {c2});'
            'color:rgba(255,255,255,0.86);'
            'font-size:12px;font-weight:700;letter-spacing:1px;border:none;}'
        )
        cover_local = str(self.item.get('cover_local', '')).strip()
        if cover_local and Path(cover_local).exists():
            pix = QtGui.QPixmap(cover_local)
            if not pix.isNull():
                self.hero.setPixmap(pix.scaled(244, 122, QtCore.Qt.KeepAspectRatioByExpanding, QtCore.Qt.SmoothTransformation))
                self.hero.setText('')
        root.addWidget(self.hero, 1)

        meta = QtWidgets.QFrame()
        meta.setObjectName('tile_meta')
        m = QtWidgets.QVBoxLayout(meta)
        m.setContentsMargins(10, 8, 10, 8)
        m.setSpacing(4)

        top = QtWidgets.QHBoxLayout()
        top.setContentsMargins(0, 0, 0, 0)
        top.setSpacing(6)
        self.owned_lbl = QtWidgets.QLabel('OWNED' if self.owned else '')
        self.owned_lbl.setObjectName('tile_owned')
        self.price_lbl = QtWidgets.QLabel(self._price_text())
        self.price_lbl.setObjectName('tile_price')
        top.addWidget(self.owned_lbl, 0)
        top.addStretch(1)
        top.addWidget(self.price_lbl, 0)

        self.title_lbl = QtWidgets.QLabel(str(self.item.get('name', 'Item')))
        self.title_lbl.setObjectName('tile_title')
        self.title_lbl.setWordWrap(True)
        self.desc_lbl = QtWidgets.QLabel(self._short_desc(self.item.get('desc', '')))
        self.desc_lbl.setObjectName('tile_desc')
        self.src_lbl = QtWidgets.QLabel(str(self.item.get('source', 'XUI')).upper())
        self.src_lbl.setObjectName('tile_source')

        m.addLayout(top)
        m.addWidget(self.title_lbl, 0)
        m.addWidget(self.desc_lbl, 0)
        m.addWidget(self.src_lbl, 0)
        root.addWidget(meta, 0)

    def _apply_style(self):
        border = '#7fbe32' if self.selected else '#d2d9df'
        self.setStyleSheet(
            f'''
            QFrame#store_tile {{
                background:#ffffff;
                border:2px solid {border};
                border-radius:2px;
            }}
            QFrame#store_tile:hover {{
                border:2px solid #6db429;
            }}
            QFrame#tile_meta {{
                background:#0f1218;
                border:none;
                border-top:1px solid #222a34;
                border-radius:0px;
            }}
            QLabel#tile_owned {{
                color:#b8ff80;
                font-size:11px;
                font-weight:700;
            }}
            QLabel#tile_price {{
                color:#9ad26a;
                font-size:11px;
                font-weight:700;
            }}
            QLabel#tile_title {{
                color:#ffffff;
                font-size:14px;
                font-weight:800;
            }}
            QLabel#tile_desc {{
                color:#b8c2cf;
                font-size:11px;
            }}
            QLabel#tile_source {{
                color:#78ad45;
                font-size:10px;
                font-weight:700;
            }}
            '''
        )

    def set_owned(self, owned):
        self.owned = bool(owned)
        self.owned_lbl.setText('OWNED' if self.owned else '')

    def set_selected(self, selected):
        self.selected = bool(selected)
        self._apply_style()

    def mousePressEvent(self, event):
        self.clicked.emit(self.item)
        super().mousePressEvent(event)


class VirtualKeyboardDialog(QtWidgets.QDialog):
    def __init__(self, parent=None, initial=''):
        super().__init__(parent)
        self.setWindowTitle('Virtual Keyboard')
        self.setModal(True)
        self.resize(860, 340)
        self.text = str(initial or '')
        self._kb_rows = []
        self._kb_focus_row = 0
        self._kb_focus_col = 0
        self._build()
        self.line.setText(self.text)
        QtCore.QTimer.singleShot(0, lambda: self._focus_button(0, 0))

    def _build(self):
        root = QtWidgets.QVBoxLayout(self)
        root.setContentsMargins(12, 12, 12, 12)
        root.setSpacing(8)

        self.line = QtWidgets.QLineEdit()
        self.line.setPlaceholderText('Type text...')
        self.line.returnPressed.connect(self.accept)
        self.line.setFocusPolicy(QtCore.Qt.ClickFocus)
        self.line.installEventFilter(self)
        root.addWidget(self.line, 0)

        grid_wrap = QtWidgets.QFrame()
        grid = QtWidgets.QGridLayout(grid_wrap)
        grid.setContentsMargins(0, 0, 0, 0)
        grid.setHorizontalSpacing(6)
        grid.setVerticalSpacing(6)

        rows = [
            list('1234567890'),
            list('QWERTYUIOP'),
            list('ASDFGHJKL'),
            list('ZXCVBNM'),
        ]
        r = 0
        for chars in rows:
            c = 0
            row_buttons = []
            for ch in chars:
                b = QtWidgets.QPushButton(ch)
                b.setMinimumHeight(38)
                b.clicked.connect(lambda _=False, ch=ch: self.line.insert(ch))
                b.installEventFilter(self)
                grid.addWidget(b, r, c, 1, 1)
                row_buttons.append(b)
                c += 1
            if row_buttons:
                self._kb_rows.append(row_buttons)
            r += 1
        root.addWidget(grid_wrap, 1)

        actions = QtWidgets.QHBoxLayout()
        actions.setSpacing(8)
        btn_space = QtWidgets.QPushButton('Space')
        btn_back = QtWidgets.QPushButton('Backspace')
        btn_clear = QtWidgets.QPushButton('Clear')
        btn_ok = QtWidgets.QPushButton('OK')
        btn_cancel = QtWidgets.QPushButton('Cancel')
        btn_space.clicked.connect(lambda: self.line.insert(' '))
        btn_back.clicked.connect(self.line.backspace)
        btn_clear.clicked.connect(self.line.clear)
        btn_ok.clicked.connect(self.accept)
        btn_cancel.clicked.connect(self.reject)
        for b in (btn_space, btn_back, btn_clear, btn_ok, btn_cancel):
            b.installEventFilter(self)
        actions.addWidget(btn_space, 0)
        actions.addWidget(btn_back, 0)
        actions.addWidget(btn_clear, 0)
        actions.addStretch(1)
        actions.addWidget(btn_ok, 0)
        actions.addWidget(btn_cancel, 0)
        self._kb_rows.append([btn_space, btn_back, btn_clear, btn_ok, btn_cancel])
        root.addLayout(actions, 0)

        self.setStyleSheet('''
            QDialog { background:#e8edf1; }
            QLineEdit {
                background:#ffffff; color:#1f2b37; border:1px solid #6e8a55;
                padding:8px; font-size:18px; font-weight:700;
            }
            QPushButton {
                background:#58ac34; color:#ffffff; border:1px solid #45872a;
                padding:6px 8px; font-size:16px; font-weight:800;
            }
            QPushButton:focus { border:2px solid #ffffff; }
            QPushButton:hover { background:#48952a; }
        ''')

    def _focus_button(self, row, col):
        if not self._kb_rows:
            return
        row = max(0, min(len(self._kb_rows) - 1, int(row)))
        buttons = self._kb_rows[row]
        if not buttons:
            return
        col = max(0, min(len(buttons) - 1, int(col)))
        self._kb_focus_row = row
        self._kb_focus_col = col
        btn = buttons[col]
        btn.setFocus(QtCore.Qt.OtherFocusReason)

    def _move_focus(self, dr=0, dc=0):
        if not self._kb_rows:
            return
        row = self._kb_focus_row + int(dr)
        row = max(0, min(len(self._kb_rows) - 1, row))
        cur_col = self._kb_focus_col + int(dc)
        self._focus_button(row, cur_col)

    def _click_focused(self):
        if not self._kb_rows:
            return
        row = max(0, min(len(self._kb_rows) - 1, self._kb_focus_row))
        buttons = self._kb_rows[row]
        if not buttons:
            return
        col = max(0, min(len(buttons) - 1, self._kb_focus_col))
        btn = buttons[col]
        btn.click()
        btn.setFocus(QtCore.Qt.OtherFocusReason)

    def eventFilter(self, obj, event):
        if event.type() == QtCore.QEvent.KeyPress:
            if event.key() in (
                QtCore.Qt.Key_Left, QtCore.Qt.Key_Right,
                QtCore.Qt.Key_Up, QtCore.Qt.Key_Down,
                QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter,
                QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back,
                QtCore.Qt.Key_Space, QtCore.Qt.Key_Backspace,
                QtCore.Qt.Key_A, QtCore.Qt.Key_B,
            ):
                self.keyPressEvent(event)
                return True
        return super().eventFilter(obj, event)

    def keyPressEvent(self, e):
        k = e.key()
        if k in (QtCore.Qt.Key_Left,):
            self._move_focus(0, -1)
            return
        if k in (QtCore.Qt.Key_Right,):
            self._move_focus(0, 1)
            return
        if k in (QtCore.Qt.Key_Up,):
            self._move_focus(-1, 0)
            return
        if k in (QtCore.Qt.Key_Down,):
            self._move_focus(1, 0)
            return
        if k in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter, QtCore.Qt.Key_A):
            self._click_focused()
            return
        if k in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back, QtCore.Qt.Key_B):
            self.reject()
            return
        if k == QtCore.Qt.Key_Space:
            self.line.insert(' ')
            return
        if k == QtCore.Qt.Key_Backspace:
            self.line.backspace()
            return
        super().keyPressEvent(e)

    def get_text(self):
        return self.line.text().strip()


class StoreInstallProgressDialog(QtWidgets.QDialog):
    def __init__(self, app_title='App', parent=None):
        super().__init__(parent)
        self._phase = 0
        self.setWindowTitle('Install in Progress')
        self.setWindowFlags(QtCore.Qt.Dialog | QtCore.Qt.FramelessWindowHint)
        self.setModal(True)
        self.resize(760, 360)
        self.setStyleSheet('''
            QDialog { background:#e7eaee; border:2px solid rgba(242,247,250,0.9); }
            QLabel#title { color:#f6f8fb; background:#151a1f; font-size:33px; font-weight:800; padding:8px 14px; }
            QLabel#app { color:#293645; font-size:30px; font-weight:800; }
            QLabel#body { color:#27313a; font-size:24px; font-weight:700; }
            QLabel#detail { color:#34414e; font-size:17px; font-weight:700; }
            QProgressBar {
                border:1px solid #c9d3db;
                border-radius:2px;
                background:#dfe4e8;
                height:24px;
                text-align:center;
                color:#1e252c;
                font-size:14px;
                font-weight:800;
            }
            QProgressBar::chunk {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #37b935, stop:1 #5dd43f);
            }
        ''')
        root = QtWidgets.QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)
        self.lbl_title = QtWidgets.QLabel('Install in Progress')
        self.lbl_title.setObjectName('title')
        root.addWidget(self.lbl_title)
        body = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(body)
        lay.setContentsMargins(28, 24, 28, 20)
        lay.setSpacing(16)
        self.lbl_app = QtWidgets.QLabel(str(app_title or 'App'))
        self.lbl_app.setObjectName('app')
        lay.addWidget(self.lbl_app)
        self.lbl = QtWidgets.QLabel('Installing app. Do not turn off or unplug your console.')
        self.lbl.setObjectName('body')
        self.lbl.setWordWrap(True)
        lay.addWidget(self.lbl)
        self.bar = QtWidgets.QProgressBar()
        self.bar.setRange(0, 100)
        self.bar.setValue(7)
        self.bar.setFormat('%p%')
        lay.addWidget(self.bar)
        self.detail = QtWidgets.QLabel('Preparing installer...')
        self.detail.setObjectName('detail')
        lay.addWidget(self.detail)
        lay.addStretch(1)
        root.addWidget(body, 1)
        self._tick = QtCore.QTimer(self)
        self._tick.timeout.connect(self._pulse)
        self._tick.start(130)

    def _pulse(self):
        cur = self.bar.value()
        target = 93 if self._phase < 1 else 98
        nxt = min(target, cur + 1)
        self.bar.setValue(nxt)

    def set_detail(self, text):
        t = str(text or '').strip()
        if t:
            self.detail.setText(t[:220])
        if self.bar.value() < 93:
            self.bar.setValue(min(93, self.bar.value() + 1))

    def finish_ok(self, text='Install completed successfully.'):
        self._phase = 1
        self.bar.setValue(100)
        self.detail.setText(str(text or 'Install completed successfully.'))

    def finish_error(self, text='Install failed.'):
        self._phase = 1
        self.bar.setValue(min(100, max(self.bar.value(), 97)))
        self.detail.setText(str(text or 'Install failed.'))


class StoreWindow(QtWidgets.QMainWindow):
    FILTER_MAP = {
        'All': None,
        'Xbox One': {'Games'},
        'Xbox 360': {'MiniGames'},
        'Windows 8': {'Apps', 'Themes'},
        'Windows Phone': {'Accessories', 'MiniGames'},
        'Web': {'Browser'},
        'Free': 'pricing:free',
        'Paid': 'pricing:paid',
    }

    def __init__(self):
        super().__init__()
        self.setWindowTitle('XUI Marketplace')
        self.resize(1280, 780)
        self.store_data = {'items': []}
        self.inventory = {'items': []}
        self.category = 'All'
        self.search_text = ''
        self.filtered_rows = []
        self.selected_item_id = ''
        self.cat_buttons = {}
        self.tile_widgets = []
        self.sync_proc = None
        self._gamepad = None
        self._gamepad_timer = None
        self._pad_prev = {}
        self._search_kbd_opening = False
        self._busy_prev = {}
        self._install_proc = None
        self._install_progress = None
        self._install_output = ''
        self._install_label = 'App'
        self._install_success_msg = ''
        self._install_fail_msg = ''
        self._install_launch_cmd = ''
        self.reflow_timer = QtCore.QTimer(self)
        self.reflow_timer.setSingleShot(True)
        self.reflow_timer.timeout.connect(self._rebuild_tile_grid)
        self._build()
        try:
            ensure_achievements(5000)
        except Exception:
            pass
        self.reload()
        self._setup_gamepad()

    def _build(self):
        root = QtWidgets.QWidget()
        self.setCentralWidget(root)
        v = QtWidgets.QVBoxLayout(root)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(0)

        header = QtWidgets.QFrame()
        header.setObjectName('header_white')
        hl = QtWidgets.QHBoxLayout(header)
        hl.setContentsMargins(20, 12, 20, 12)
        hl.setSpacing(12)

        mark = QtWidgets.QLabel('X')
        mark.setObjectName('logo_mark')
        mark.setAlignment(QtCore.Qt.AlignCenter)
        mark.setFixedSize(38, 38)
        logo = QtWidgets.QLabel('XBOX')
        logo.setObjectName('logo_word')
        hl.addWidget(mark, 0)
        hl.addWidget(logo, 0)
        hl.addStretch(1)

        self.balance_lbl = QtWidgets.QLabel('Balance: EUR 0.00')
        self.balance_lbl.setObjectName('balance')
        acc = QtWidgets.QLabel('My Account  |  Join Now  |  Sign In')
        acc.setObjectName('account_links')
        hl.addWidget(self.balance_lbl, 0)
        hl.addSpacing(16)
        hl.addWidget(acc, 0)
        v.addWidget(header, 0)

        nav = QtWidgets.QFrame()
        nav.setObjectName('green_nav')
        nav_l = QtWidgets.QHBoxLayout(nav)
        nav_l.setContentsMargins(16, 8, 16, 8)
        nav_l.setSpacing(2)
        for name in ['Xbox One', 'Xbox 360', 'Xbox Live Gold', 'Social', 'Games', 'Video', 'Music', 'Support']:
            b = QtWidgets.QPushButton(name)
            b.setObjectName('global_nav_btn')
            b.setProperty('active', str(name == 'Games').lower())
            b.clicked.connect(lambda _=False, name=name: self._on_global_nav(name))
            nav_l.addWidget(b, 0)
        nav_l.addStretch(1)
        self.search = QtWidgets.QLineEdit()
        self.search.setObjectName('search')
        self.search.setPlaceholderText('Search Games')
        self.search.installEventFilter(self)
        self.search.textChanged.connect(self.set_search)
        search_btn = QtWidgets.QPushButton('Search')
        search_btn.setObjectName('search_btn')
        search_btn.clicked.connect(lambda: self.set_search(self.search.text()))
        kb_btn = QtWidgets.QPushButton('Keyboard')
        kb_btn.setObjectName('search_btn')
        kb_btn.clicked.connect(self.open_virtual_keyboard)
        nav_l.addWidget(self.search, 0)
        nav_l.addWidget(search_btn, 0)
        nav_l.addWidget(kb_btn, 0)
        v.addWidget(nav, 0)

        page = QtWidgets.QWidget()
        page_l = QtWidgets.QVBoxLayout(page)
        page_l.setContentsMargins(16, 14, 16, 12)
        page_l.setSpacing(10)

        title_row = QtWidgets.QHBoxLayout()
        title_row.setContentsMargins(0, 0, 0, 0)
        self.page_title = QtWidgets.QLabel('Xbox Games')
        self.page_title.setObjectName('page_title')
        self.rotation_lbl = QtWidgets.QLabel('Rotation: -')
        self.rotation_lbl.setObjectName('rotation_lbl')
        title_row.addWidget(self.page_title, 0)
        title_row.addStretch(1)
        title_row.addWidget(self.rotation_lbl, 0)
        page_l.addLayout(title_row)

        filters = QtWidgets.QHBoxLayout()
        filters.setContentsMargins(0, 0, 0, 0)
        filters.setSpacing(2)
        for name in ['Xbox One', 'Xbox 360', 'Windows 8', 'Windows Phone', 'Web', 'Free', 'Paid', 'All']:
            b = QtWidgets.QPushButton(name)
            b.setObjectName('platform_btn')
            b.clicked.connect(lambda _=False, name=name: self.set_category(name))
            filters.addWidget(b, 0)
            self.cat_buttons[name] = b
        filters.addStretch(1)
        page_l.addLayout(filters)

        self.scroll = QtWidgets.QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setObjectName('tiles_scroll')
        self.tile_host = QtWidgets.QWidget()
        self.tile_grid = QtWidgets.QGridLayout(self.tile_host)
        self.tile_grid.setContentsMargins(0, 0, 0, 0)
        self.tile_grid.setHorizontalSpacing(12)
        self.tile_grid.setVerticalSpacing(12)
        self.scroll.setWidget(self.tile_host)
        page_l.addWidget(self.scroll, 1)

        details = QtWidgets.QFrame()
        details.setObjectName('details_panel')
        dl = QtWidgets.QVBoxLayout(details)
        dl.setContentsMargins(12, 10, 12, 10)
        dl.setSpacing(8)

        self.sel_name = QtWidgets.QLabel('Select an item')
        self.sel_name.setObjectName('sel_name')
        self.sel_meta = QtWidgets.QLabel('Category | Price | State')
        self.sel_meta.setObjectName('sel_meta')
        self.sel_desc = QtWidgets.QLabel('Choose a tile to view details.')
        self.sel_desc.setWordWrap(True)
        self.sel_desc.setObjectName('sel_desc')

        actions = QtWidgets.QHBoxLayout()
        actions.setContentsMargins(0, 0, 0, 0)
        actions.setSpacing(6)
        self.buy_btn = QtWidgets.QPushButton('Buy')
        self.install_btn = QtWidgets.QPushButton('Install')
        self.launch_btn = QtWidgets.QPushButton('Launch')
        inv_btn = QtWidgets.QPushButton('Inventory')
        refresh_btn = QtWidgets.QPushButton('Refresh')
        sync_btn = QtWidgets.QPushButton('Sync Sources')
        close_btn = QtWidgets.QPushButton('Close')
        self.buy_btn.clicked.connect(self.buy_selected)
        self.install_btn.clicked.connect(self.install_selected)
        self.launch_btn.clicked.connect(self.launch_selected)
        inv_btn.clicked.connect(self.show_inventory)
        refresh_btn.clicked.connect(self.reload)
        sync_btn.clicked.connect(self.sync_sources)
        close_btn.clicked.connect(self.close)
        actions.addWidget(self.buy_btn)
        actions.addWidget(self.install_btn)
        actions.addWidget(self.launch_btn)
        actions.addWidget(inv_btn)
        actions.addWidget(refresh_btn)
        actions.addWidget(sync_btn)
        actions.addStretch(1)
        actions.addWidget(close_btn)

        self.info_lbl = QtWidgets.QLabel('Marketplace ready.')
        self.info_lbl.setObjectName('info_lbl')

        dl.addWidget(self.sel_name, 0)
        dl.addWidget(self.sel_meta, 0)
        dl.addWidget(self.sel_desc, 0)
        dl.addLayout(actions)
        dl.addWidget(self.info_lbl, 0)
        page_l.addWidget(details, 0)

        v.addWidget(page, 1)

        self.setStyleSheet('''
            QMainWindow { background:#f4f4f4; color:#1f2b37; }
            QFrame#header_white {
                background:#ffffff;
                border-bottom:1px solid #d8d8d8;
            }
            QLabel#logo_mark {
                background:qradialgradient(cx:0.3, cy:0.3, radius:0.9, fx:0.35, fy:0.35, stop:0 #f6f6f6, stop:1 #9fa5aa);
                color:#4da125;
                font-size:23px;
                font-weight:900;
                border-radius:19px;
                border:1px solid #b7bcc0;
            }
            QLabel#logo_word {
                color:#4b4b4b;
                font-size:40px;
                font-weight:700;
                letter-spacing:1px;
            }
            QLabel#balance {
                color:#3f5c1f;
                font-size:19px;
                font-weight:800;
            }
            QLabel#account_links {
                color:#70a639;
                font-size:14px;
                font-weight:600;
            }
            QFrame#green_nav { background:#75b93b; border-top:1px solid #679f35; border-bottom:1px solid #5f9630; }
            QPushButton#global_nav_btn {
                background:transparent;
                color:#f4ffe9;
                border:none;
                padding:7px 10px;
                font-size:16px;
                font-weight:700;
                text-align:left;
            }
            QPushButton#global_nav_btn[active="true"] {
                color:#ffffff;
                background:rgba(0,0,0,0.12);
            }
            QPushButton#global_nav_btn:hover {
                background:rgba(0,0,0,0.18);
            }
            QLineEdit#search {
                background:#ffffff;
                color:#273220;
                border:1px solid #4f7f24;
                min-width:230px;
                padding:6px 8px;
                font-size:15px;
                font-weight:600;
            }
            QPushButton#search_btn {
                background:#4f8e26;
                color:#ffffff;
                border:1px solid #3f7420;
                padding:6px 10px;
                font-size:14px;
                font-weight:700;
            }
            QPushButton#search_btn:hover { background:#417e1f; }
            QLabel#page_title {
                color:#4f5865;
                font-size:54px;
                font-weight:700;
            }
            QLabel#rotation_lbl {
                color:#6a7784;
                font-size:16px;
                font-weight:600;
            }
            QPushButton#platform_btn {
                background:transparent;
                border:none;
                color:#76ad37;
                font-size:33px;
                font-weight:700;
                padding:2px 10px 6px 0px;
                text-align:left;
            }
            QPushButton#platform_btn:hover {
                color:#5f9328;
            }
            QScrollArea#tiles_scroll {
                background:#ffffff;
                border:1px solid #d4d8dc;
            }
            QFrame#details_panel {
                background:#ffffff;
                border:1px solid #ced4da;
            }
            QLabel#sel_name {
                color:#26333f;
                font-size:22px;
                font-weight:800;
            }
            QLabel#sel_meta {
                color:#547038;
                font-size:15px;
                font-weight:700;
            }
            QLabel#sel_desc {
                color:#506171;
                font-size:14px;
                font-weight:600;
            }
            QLabel#info_lbl {
                color:#2b4a6b;
                font-size:14px;
                font-weight:700;
            }
            QPushButton {
                background:#4ea42a;
                color:#ffffff;
                border:1px solid #3b7f1f;
                padding:6px 12px;
                font-size:14px;
                font-weight:800;
            }
            QPushButton:hover {
                background:#3f9120;
            }
            QPushButton:disabled {
                color:#ccddbf;
                background:#8db380;
                border:1px solid #80a474;
            }
        ''')
        self._update_cat_styles()

    def _set_busy(self, busy=True):
        busy = bool(busy)
        controls = [self.buy_btn, self.install_btn, self.launch_btn, self.search]
        if busy:
            self._busy_prev = {id(w): bool(w.isEnabled()) for w in controls}
            for w in controls:
                w.setEnabled(False)
            return
        for w in controls:
            w.setEnabled(bool(self._busy_prev.get(id(w), True)))
        self._busy_prev = {}

    def sync_sources(self):
        if self.sync_proc and self.sync_proc.state() != QtCore.QProcess.NotRunning:
            self.info_lbl.setText('Source sync already running...')
            return
        script = str(XUI_BIN / 'xui_store_sync_sources.sh')
        if not Path(script).exists():
            self.info_lbl.setText('Missing source sync script.')
            return
        self.info_lbl.setText('Syncing Flathub / Itch.io / Game Jolt...')
        self.sync_proc = QtCore.QProcess(self)
        self.sync_proc.setProgram('/bin/sh')
        self.sync_proc.setArguments(['-lc', script])
        self.sync_proc.finished.connect(self._on_sync_finished)
        self.sync_proc.start()

    def _on_sync_finished(self, code, status):
        ok = (int(code) == 0 and status == QtCore.QProcess.NormalExit)
        if ok:
            self.reload('Sources synced. New games/apps imported.')
        else:
            self.reload('Source sync failed. Check xui_store_sync_sources.sh.')

    def _on_global_nav(self, name):
        key = str(name or '').strip()
        if key in ('Xbox One', 'Xbox 360'):
            self.set_category(key)
            return
        if key == 'Games':
            self.set_category('All')
            return
        self.info_lbl.setText(f'{key} section is visual-only in this build.')

    def _run_terminal(self, cmd):
        hold = str(cmd) + '; rc=$?; echo; echo "[XUI] Exit code: $rc"; echo "[XUI] Press Enter to close..."; read -r _'
        term = None
        args = []
        if shutil.which('x-terminal-emulator'):
            term = 'x-terminal-emulator'
            args = ['-e', '/bin/bash', '-lc', hold]
        elif shutil.which('gnome-terminal'):
            term = 'gnome-terminal'
            args = ['--', '/bin/bash', '-lc', hold]
        elif shutil.which('konsole'):
            term = 'konsole'
            args = ['-e', '/bin/bash', '-lc', hold]
        elif shutil.which('xterm'):
            term = 'xterm'
            args = ['-e', '/bin/bash', '-lc', hold]
        if term:
            QtCore.QProcess.startDetached(term, args)
            return True
        return QtCore.QProcess.startDetached('/bin/bash', ['-lc', hold])

    def _run_detached(self, cmd):
        return QtCore.QProcess.startDetached('/bin/sh', ['-c', cmd])

    def _close_install_progress(self):
        dlg = self._install_progress
        self._install_progress = None
        if dlg is None:
            return
        try:
            dlg.hide()
        except Exception:
            pass
        try:
            dlg.deleteLater()
        except Exception:
            pass

    def _on_install_output(self):
        proc = self._install_proc
        if proc is None:
            return
        try:
            chunk = bytes(proc.readAllStandardOutput()).decode('utf-8', errors='ignore')
        except Exception:
            chunk = ''
        if not chunk:
            return
        self._install_output = (self._install_output + chunk)[-26000:]
        dlg = self._install_progress
        if dlg is None:
            return
        lines = [ln.strip() for ln in self._install_output.splitlines() if ln.strip()]
        if lines:
            dlg.set_detail(lines[-1][:180])

    def _on_install_error(self, err):
        self._on_install_output()
        proc = self._install_proc
        self._install_proc = None
        if proc is not None:
            proc.deleteLater()
        dlg = self._install_progress
        if dlg is not None and hasattr(dlg, 'finish_error'):
            dlg.finish_error('Installer process error.')
        self._close_install_progress()
        self._set_busy(False)
        self.reload(f'Install failed: process error {err}')

    def _on_install_finished(self, code, status):
        self._on_install_output()
        proc = self._install_proc
        self._install_proc = None
        if proc is not None:
            proc.deleteLater()
        ok = (status == QtCore.QProcess.NormalExit and int(code) == 0)
        if ok:
            dlg = self._install_progress
            if dlg is not None and hasattr(dlg, 'finish_ok'):
                dlg.finish_ok('Install completed successfully.')
            QtCore.QTimer.singleShot(260, self._close_install_progress)
            launch_cmd = str(self._install_launch_cmd or '').strip()
            if launch_cmd:
                self._run_detached(launch_cmd)
            self._set_busy(False)
            self.reload(str(self._install_success_msg or f'Install completed: {self._install_label}'))
            return
        dlg = self._install_progress
        if dlg is not None and hasattr(dlg, 'finish_error'):
            dlg.finish_error('Install failed.')
        self._close_install_progress()
        lines = [ln.strip() for ln in self._install_output.splitlines() if ln.strip()]
        tail = '\n'.join(lines[-10:]).strip()
        fail_txt = str(self._install_fail_msg or f'Install failed: {self._install_label}')
        self._set_busy(False)
        if tail:
            self.reload(f'{fail_txt} | {tail}')
        else:
            self.reload(fail_txt)

    def _run_install_task(self, title, shell_cmd, success_msg='', fail_msg='', launch_cmd=''):
        if self._install_proc is not None and self._install_proc.state() != QtCore.QProcess.NotRunning:
            self.reload('Another install is already running.')
            return
        self._install_output = ''
        self._install_label = str(title or 'App')
        self._install_success_msg = str(success_msg or '')
        self._install_fail_msg = str(fail_msg or '')
        self._install_launch_cmd = str(launch_cmd or '')
        self._set_busy(True)
        dlg = StoreInstallProgressDialog(self._install_label, self)
        dlg.show()
        self._install_progress = dlg
        proc = QtCore.QProcess(self)
        env = QtCore.QProcessEnvironment.systemEnvironment()
        env.insert('XUI_NONINTERACTIVE', '1')
        env.insert('XUI_FORCE_ELEVATED', '1')
        env.insert('DEBIAN_FRONTEND', 'noninteractive')
        proc.setProcessEnvironment(env)
        proc.setProgram('/bin/sh')
        proc.setArguments(['-lc', str(shell_cmd)])
        proc.setProcessChannelMode(QtCore.QProcess.MergedChannels)
        proc.readyReadStandardOutput.connect(self._on_install_output)
        proc.finished.connect(self._on_install_finished)
        proc.errorOccurred.connect(self._on_install_error)
        self._install_proc = proc
        proc.start()

    def _inventory_ids(self):
        inv = self.inventory.get('items', [])
        ids = set()
        for x in inv:
            try:
                ids.add(str(x.get('id', '')).strip())
            except Exception:
                continue
        return ids

    def _item_matches(self, item):
        cat = str(item.get('category', 'Apps'))
        allowed = self.FILTER_MAP.get(self.category)
        if isinstance(allowed, str) and allowed.startswith('pricing:'):
            want = allowed.split(':', 1)[1].strip().lower()
            pricing = str(item.get('pricing', 'free')).strip().lower()
            if pricing != want:
                return False
        elif allowed and cat not in allowed:
            return False
        q = self.search_text.strip().lower()
        if not q:
            return True
        blob = ' '.join([
            str(item.get('name', '')),
            str(item.get('desc', '')),
            str(item.get('id', '')),
            cat,
            str(item.get('pricing', '')),
            str(item.get('source', '')),
        ]).lower()
        return q in blob

    def _update_cat_styles(self):
        for cat, btn in self.cat_buttons.items():
            if cat == self.category:
                btn.setStyleSheet(
                    'color:#1f1f1f; border-bottom:4px solid #75b93b;'
                    'font-size:36px; font-weight:800;'
                )
            else:
                btn.setStyleSheet('')

    def set_category(self, cat):
        self.category = str(cat or 'All')
        if self.category not in self.FILTER_MAP:
            self.category = 'All'
        self._update_cat_styles()
        self._refresh_tiles()

    def set_search(self, text):
        self.search_text = str(text or '')
        self._refresh_tiles()

    def _search_input_active(self):
        try:
            return bool(self.search is not None and self.search.hasFocus())
        except Exception:
            return False

    def open_virtual_keyboard(self):
        if self._search_kbd_opening:
            return
        self._search_kbd_opening = True
        try:
            d = VirtualKeyboardDialog(self, self.search.text())
            if d.exec_() == QtWidgets.QDialog.Accepted:
                self.search.setText(d.get_text())
                self.search.setFocus()
        finally:
            self._search_kbd_opening = False

    def eventFilter(self, obj, event):
        if obj is self.search and event.type() == QtCore.QEvent.KeyPress:
            if event.key() in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter):
                QtCore.QTimer.singleShot(0, self.open_virtual_keyboard)
                return True
        return super().eventFilter(obj, event)

    def _tile_columns(self):
        viewport_w = max(1, self.scroll.viewport().width())
        return max(1, min(6, viewport_w // 260))

    def _clear_tile_grid(self):
        while self.tile_grid.count():
            child = self.tile_grid.takeAt(0)
            w = child.widget()
            if w is not None:
                w.deleteLater()
        self.tile_widgets = []

    def _rebuild_tile_grid(self):
        self._clear_tile_grid()
        if not self.filtered_rows:
            empty = QtWidgets.QLabel('No items available for this filter.')
            empty.setStyleSheet('color:#5d6d7d; font-size:18px; font-weight:700; padding:18px;')
            self.tile_grid.addWidget(empty, 0, 0)
            self.selected_item_id = ''
            self._update_selected_panel()
            return

        inv_ids = self._inventory_ids()
        cols = self._tile_columns()
        for i, item in enumerate(self.filtered_rows):
            iid = str(item.get('id', ''))
            tile = StoreTile(item, iid in inv_ids)
            tile.clicked.connect(self._on_tile_clicked)
            self.tile_widgets.append(tile)
            r = i // cols
            c = i % cols
            self.tile_grid.addWidget(tile, r, c)
        self.tile_grid.setColumnStretch(cols, 1)

        visible_ids = {str(x.get('id', '')) for x in self.filtered_rows}
        if self.selected_item_id not in visible_ids:
            self.selected_item_id = str(self.filtered_rows[0].get('id', ''))
        self._apply_selection()

    def _on_tile_clicked(self, item):
        self.selected_item_id = str((item or {}).get('id', '')).strip()
        self._apply_selection()

    def _selected_item(self):
        sid = str(self.selected_item_id or '').strip()
        if not sid and self.filtered_rows:
            sid = str(self.filtered_rows[0].get('id', '')).strip()
            self.selected_item_id = sid
        for item in self.filtered_rows:
            if str(item.get('id', '')).strip() == sid:
                return item
        return None

    def _apply_selection(self):
        sid = str(self.selected_item_id or '').strip()
        for tile in self.tile_widgets:
            tid = str(tile.item.get('id', '')).strip()
            tile.set_selected(bool(sid and tid == sid))
        self._update_selected_panel()

    def _update_selected_panel(self):
        item = self._selected_item()
        if item is None:
            self.sel_name.setText('Select an item')
            self.sel_meta.setText('Category | Price | State')
            self.sel_desc.setText('Choose a tile to view details.')
            self.buy_btn.setText('Buy')
            self.buy_btn.setEnabled(False)
            self.install_btn.setEnabled(False)
            self.launch_btn.setEnabled(False)
            return
        iid = str(item.get('id', ''))
        name = str(item.get('name', iid))
        cat = str(item.get('category', 'Apps'))
        desc = str(item.get('desc', 'No description available.'))
        price = float(item.get('price', 0))
        pricing = str(item.get('pricing', 'free')).strip().lower()
        external_paid = bool(item.get('external_checkout', False)) and pricing == 'paid'
        if external_paid:
            price_txt = 'PAID (Official Store)'
        elif pricing == 'paid':
            price_txt = f'EUR {price:.2f}' if price > 0 else 'PAID'
        else:
            price_txt = 'FREE'
        owned = iid in self._inventory_ids()
        state = 'OFFICIAL PURCHASE' if external_paid else ('OWNED' if owned else 'NOT OWNED')
        source = str(item.get('source', 'XUI'))
        install_cmd = str(item.get('install', '')).strip()
        launch_cmd = str(item.get('launch', '')).strip()
        purchase_url = str(item.get('purchase_url', '')).strip()

        self.sel_name.setText(name)
        self.sel_meta.setText(f'{cat} | {source} | {price_txt} | {state}')
        self.sel_desc.setText(desc)
        self.buy_btn.setText('Buy Official' if external_paid else 'Buy')
        if external_paid:
            self.buy_btn.setEnabled(bool(purchase_url or launch_cmd))
        else:
            self.buy_btn.setEnabled((pricing == 'paid') and (not owned))
        self.install_btn.setEnabled(bool(install_cmd) and (owned or pricing == 'free'))
        can_launch = bool(launch_cmd) and (owned or pricing == 'free' or external_paid)
        self.launch_btn.setEnabled(can_launch)

    def reload(self, msg=''):
        self.store_data = ensure_catalog_minimum(620)
        self.inventory = load_inventory()
        self._refresh_tiles()
        active_n = len(self.store_data.get('items', []))
        total_n = int(self.store_data.get('rotation_total_count', active_n))
        rot_day = str(self.store_data.get('rotation_day', '-'))
        self.balance_lbl.setText(f'Balance: EUR {get_balance():.2f}')
        self.rotation_lbl.setText(f'Catalog today {active_n}/{total_n} | Rotation {rot_day}')
        self.info_lbl.setText(msg or f'Showing {len(self.filtered_rows)} items in {self.category}.')

    def _refresh_tiles(self):
        items = self.store_data.get('items', [])
        self.filtered_rows = [it for it in items if self._item_matches(it)]
        self._rebuild_tile_grid()
        active_n = len(items)
        total_n = int(self.store_data.get('rotation_total_count', active_n))
        rot_day = str(self.store_data.get('rotation_day', '-'))
        self.rotation_lbl.setText(f'Catalog today {active_n}/{total_n} | Rotation {rot_day}')
        self.balance_lbl.setText(f'Balance: EUR {get_balance():.2f}')
        self.info_lbl.setText(f'Showing {len(self.filtered_rows)} items in {self.category}.')

    def buy_selected(self):
        item = self._selected_item()
        if item is None:
            self.reload('Select an item to buy first.')
            return
        name = str(item.get('name', item.get('id', 'Item')))
        price = float(item.get('price', 0))
        iid = str(item.get('id', name))
        pricing = str(item.get('pricing', 'free')).strip().lower()
        external_paid = bool(item.get('external_checkout', False)) and pricing == 'paid'
        purchase_url = str(item.get('purchase_url', '')).strip()
        if external_paid:
            if purchase_url:
                target_cmd = str(XUI_BIN / 'xui_browser.sh') + ' --hub ' + shlex.quote(purchase_url)
            else:
                target_cmd = str(item.get('launch', '')).strip()
            if not target_cmd:
                self.reload('Official purchase page is missing for this item.')
                return
            self._run_detached(target_cmd)
            self.reload(f'Opening official purchase page: {name}')
            return
        inv_ids = self._inventory_ids()
        if iid in inv_ids:
            self.reload(f'You already own: {name}')
            return
        if pricing != 'paid':
            self.reload('This item is free. Use Launch or Install.')
            return
        bal = get_balance()
        if bal < price:
            self.reload('Not enough balance.')
            return
        if price > 0:
            bal = change_balance(-price)

        inv = self.inventory.get('items', [])
        inv.append({
            'id': iid,
            'name': name,
            'price': price,
            'category': str(item.get('category', 'Apps')),
            'launch': str(item.get('launch', '')),
            'install': str(item.get('install', '')),
        })
        self.inventory['items'] = inv
        save_inventory(self.inventory)
        fresh = unlock_for_event('purchase', iid, limit=3)
        ach_note = ''
        if fresh:
            ach_names = ', '.join(str(x.get('title', 'Achievement')) for x in fresh[:2])
            ach_note = f' | Achievement: {ach_names}'

        mission = complete_mission(mission_id='m3')
        install_cmd = str(item.get('install', '')).strip()
        extra = ' | Use Install to complete setup' if install_cmd else ''
        if mission.get('completed'):
            bal = float(mission.get('balance', bal))
            reward = float(mission.get('reward', 0))
            self.reload(f'Purchase OK: {name} (EUR {price:.2f}) | Mission +EUR {reward:.2f} | Balance EUR {bal:.2f}{extra}{ach_note}')
        else:
            self.reload(f'Purchase OK: {name} (EUR {price:.2f}) | Balance EUR {bal:.2f}{extra}{ach_note}')

    def install_selected(self):
        item = self._selected_item()
        if item is None:
            self.reload('Select an item to install first.')
            return
        iid = str(item.get('id', ''))
        pricing = str(item.get('pricing', 'free')).strip().lower()
        external_paid = bool(item.get('external_checkout', False)) and pricing == 'paid'
        inv_ids = self._inventory_ids()
        if iid not in inv_ids and pricing == 'paid' and not external_paid:
            self.reload('Buy this item before running install.')
            return
        cmd = str(item.get('install', '')).strip()
        if not cmd:
            if external_paid:
                self.reload('Paid external item: use Buy Official to purchase from the source store.')
                return
            self.reload('This item does not need installation.')
            return
        if iid == 'game_fnae_fangame':
            run_fnae = str(XUI_BIN / 'xui_run_fnae.sh')
            self._run_install_task(
                item.get('name', 'FNAE'),
                str(cmd),
                success_msg='FNAE installed. Launching game...',
                fail_msg='FNAE install failed. Check ~/.xui/logs/fnae_install.log.',
                launch_cmd=run_fnae,
            )
            return
        self._run_install_task(
            item.get('name', 'App'),
            cmd,
            success_msg=f'Install completed: {item.get("name", "item")}',
            fail_msg=f'Install failed: {item.get("name", "item")}',
        )

    def launch_selected(self):
        item = self._selected_item()
        if item is None:
            self.reload('Select an item to launch first.')
            return
        iid = str(item.get('id', ''))
        pricing = str(item.get('pricing', 'free')).strip().lower()
        external_paid = bool(item.get('external_checkout', False)) and pricing == 'paid'
        inv_ids = self._inventory_ids()
        if iid not in inv_ids and pricing == 'paid' and not external_paid:
            self.reload('Buy this item before launching.')
            return
        cmd = str(item.get('launch', '')).strip()
        if not cmd and external_paid:
            purchase_url = str(item.get('purchase_url', '')).strip()
            if purchase_url:
                cmd = str(XUI_BIN / 'xui_browser.sh') + ' --hub ' + shlex.quote(purchase_url)
        if not cmd:
            self.reload('No launcher defined for this item.')
            return
        self._run_detached(cmd)
        fresh = unlock_for_event('launch', iid, limit=3)
        ach_note = ''
        if fresh:
            ach_names = ', '.join(str(x.get('title', 'Achievement')) for x in fresh[:2])
            ach_note = f' | Achievement: {ach_names}'
        self.reload(f'Launched: {item.get("name", "item")}{ach_note}')

    def show_inventory(self):
        inv = self.inventory.get('items', [])
        if not inv:
            QtWidgets.QMessageBox.information(self, 'Inventory', 'No purchased items.')
            return
        lines = []
        for i, x in enumerate(inv[:400], 1):
            lines.append(
                f"{i}. {x.get('name', 'Item')} [{x.get('category', 'Apps')}] "
                f"(EUR {float(x.get('price', 0)):.2f})"
            )
        QtWidgets.QMessageBox.information(self, 'Inventory', '\n'.join(lines))

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self.reflow_timer.start(90)

    def _selected_index(self):
        sid = str(self.selected_item_id or '').strip()
        for i, item in enumerate(self.filtered_rows):
            if str(item.get('id', '')).strip() == sid:
                return i
        return 0 if self.filtered_rows else -1

    def _set_selected_index(self, idx):
        if not self.filtered_rows:
            self.selected_item_id = ''
            self._apply_selection()
            return
        idx = max(0, min(int(idx), len(self.filtered_rows) - 1))
        self.selected_item_id = str(self.filtered_rows[idx].get('id', '')).strip()
        self._apply_selection()
        self._scroll_to_selected()

    def _scroll_to_selected(self):
        sid = str(self.selected_item_id or '').strip()
        if not sid:
            return
        for tile in self.tile_widgets:
            if str(tile.item.get('id', '')).strip() == sid:
                self.scroll.ensureWidgetVisible(tile, xMargin=20, yMargin=20)
                break

    def _move_selection(self, dr=0, dc=0):
        if not self.filtered_rows:
            return
        cols = self._tile_columns()
        idx = self._selected_index()
        if idx < 0:
            idx = 0
        r = idx // cols
        c = idx % cols
        nr = max(0, r + int(dr))
        nc = max(0, c + int(dc))
        nidx = nr * cols + nc
        if nidx >= len(self.filtered_rows):
            if dr != 0:
                nidx = len(self.filtered_rows) - 1
            else:
                nidx = min(len(self.filtered_rows) - 1, r * cols + max(0, min(cols - 1, nc)))
        self._set_selected_index(nidx)

    def keyPressEvent(self, e):
        k = e.key()
        if k in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.close()
            return
        if k == QtCore.Qt.Key_F2:
            self.open_virtual_keyboard()
            return
        if k == QtCore.Qt.Key_F5:
            self.reload('Marketplace refreshed.')
            return
        if k in (QtCore.Qt.Key_Left,):
            self._move_selection(0, -1)
            return
        if k in (QtCore.Qt.Key_Right,):
            self._move_selection(0, 1)
            return
        if k in (QtCore.Qt.Key_Up,):
            self._move_selection(-1, 0)
            return
        if k in (QtCore.Qt.Key_Down,):
            self._move_selection(1, 0)
            return
        if k in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter):
            if self._search_input_active():
                self.open_virtual_keyboard()
                return
            self.launch_selected()
            return
        if k == QtCore.Qt.Key_X:
            self.buy_selected()
            return
        if k == QtCore.Qt.Key_Y:
            self.show_inventory()
            return
        if k == QtCore.Qt.Key_B:
            self.close()
            return
        if k == QtCore.Qt.Key_A:
            if self._search_input_active():
                self.open_virtual_keyboard()
                return
            self.launch_selected()
            return
        if k == QtCore.Qt.Key_Space:
            self.buy_selected()
            return
        if k == QtCore.Qt.Key_Tab:
            self.show_inventory()
            return
        super().keyPressEvent(e)

    def _setup_gamepad(self):
        if QtGamepad is None:
            return
        try:
            mgr = QtGamepad.QGamepadManager.instance()
            ids = list(mgr.connectedGamepads())
            if not ids:
                return
            self._gamepad = QtGamepad.QGamepad(ids[0], self)
            self._gamepad_timer = QtCore.QTimer(self)
            self._gamepad_timer.timeout.connect(self._poll_gamepad)
            self._gamepad_timer.start(70)
            self.info_lbl.setText('Controller connected: A=Launch X=Buy Y=Inventory B=Back F2=Keyboard.')
        except Exception:
            self._gamepad = None

    def _gp_read(self, name, default=0.0):
        gp = self._gamepad
        if gp is None:
            return default
        attr = getattr(gp, name, None)
        try:
            return attr() if callable(attr) else attr
        except Exception:
            return default

    def _poll_gamepad(self):
        gp = self._gamepad
        if gp is None:
            return
        left = bool(self._gp_read('buttonLeft', False)) or float(self._gp_read('axisLeftX', 0.0)) < -0.6
        right = bool(self._gp_read('buttonRight', False)) or float(self._gp_read('axisLeftX', 0.0)) > 0.6
        up = bool(self._gp_read('buttonUp', False)) or float(self._gp_read('axisLeftY', 0.0)) < -0.6
        down = bool(self._gp_read('buttonDown', False)) or float(self._gp_read('axisLeftY', 0.0)) > 0.6
        a = bool(self._gp_read('buttonA', False))
        b = bool(self._gp_read('buttonB', False))
        x = bool(self._gp_read('buttonX', False))
        y = bool(self._gp_read('buttonY', False))
        start = bool(self._gp_read('buttonStart', False))

        curr = {
            'left': left, 'right': right, 'up': up, 'down': down,
            'a': a, 'b': b, 'x': x, 'y': y, 'start': start,
        }

        def pressed(key):
            return curr.get(key, False) and not self._pad_prev.get(key, False)

        if pressed('left'):
            self._move_selection(0, -1)
        elif pressed('right'):
            self._move_selection(0, 1)
        elif pressed('up'):
            self._move_selection(-1, 0)
        elif pressed('down'):
            self._move_selection(1, 0)
        elif pressed('a'):
            if self._search_input_active():
                self.open_virtual_keyboard()
            else:
                self.launch_selected()
        elif pressed('x'):
            self.buy_selected()
        elif pressed('y'):
            self.show_inventory()
        elif pressed('start'):
            self.open_virtual_keyboard()
        elif pressed('b'):
            self.close()

        self._pad_prev = curr


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
  cp -f "$GAMES_DIR/store.py" "$BIN_DIR/xui_store_modern.py" || true
  chmod +x "$BIN_DIR/xui_store_modern.py" || true

  cat > "$BIN_DIR/xui_missions.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
exec "$HOME/.xui/bin/xui_python.sh" "$HOME/.xui/games/missions.py" "$@"
BASH
  chmod +x "$BIN_DIR/xui_missions.sh"

  cat > "$BIN_DIR/xui_store.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
PY="$HOME/.xui/bin/xui_python.sh"
STORE_MODERN="$HOME/.xui/bin/xui_store_modern.py"
STORE_LEGACY="$HOME/.xui/games/store.py"

if [ -f "$STORE_MODERN" ]; then
  exec "$PY" "$STORE_MODERN" "$@"
fi

# If legacy file is already modernized, use it.
if [ -f "$STORE_LEGACY" ] && grep -q 'class StoreTile' "$STORE_LEGACY" 2>/dev/null; then
  exec "$PY" "$STORE_LEGACY" "$@"
fi

# Try self-repair once from known script locations.
for c in \
  "$PWD/xui11.sh.fixed.sh" \
  "$HOME/Downloads/xui/xui/xui11.sh.fixed.sh" \
  "/mnt/c/Users/Usuario/Downloads/xui/xui/xui11.sh.fixed.sh"
do
  if [ -f "$c" ]; then
    bash "$c" --refresh-store-ui >/dev/null 2>&1 || true
    if [ -f "$STORE_MODERN" ]; then
      exec "$PY" "$STORE_MODERN" "$@"
    fi
  fi
done

echo "Store moderna no instalada. Ejecuta: bash xui11.sh.fixed.sh --refresh-store-ui" >&2
exit 1
BASH
  chmod +x "$BIN_DIR/xui_store.sh"

  cat > "$BIN_DIR/xui_install_flatpak_game.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
APP_ID="${1:-}"
if [ -z "$APP_ID" ]; then
  echo "Usage: $0 <flatpak.app.id>" >&2
  exit 1
fi
if ! command -v flatpak >/dev/null 2>&1; then
  echo "flatpak not found. Install flatpak first." >&2
  exit 1
fi
if ! flatpak remote-list 2>/dev/null | grep -q '^flathub'; then
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
fi
flatpak install -y flathub "$APP_ID"
echo "Installed: $APP_ID"
BASH
  chmod +x "$BIN_DIR/xui_install_flatpak_game.sh"

  cat > "$BIN_DIR/xui_install_itch.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if ! command -v flatpak >/dev/null 2>&1; then
  echo "flatpak not found. Install flatpak first." >&2
  exit 1
fi
if ! flatpak remote-list 2>/dev/null | grep -q '^flathub'; then
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
fi
flatpak install -y flathub io.itch.itch
echo "Itch installed."
BASH
  chmod +x "$BIN_DIR/xui_install_itch.sh"

  cat > "$BIN_DIR/xui_itch.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if command -v flatpak >/dev/null 2>&1 && flatpak info io.itch.itch >/dev/null 2>&1; then
  exec flatpak run io.itch.itch "$@"
fi
echo "Itch app not installed. Run: $HOME/.xui/bin/xui_install_itch.sh" >&2
exit 1
BASH
  chmod +x "$BIN_DIR/xui_itch.sh"

  cat > "$BIN_DIR/xui_store_sync_sources.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
XUI="$HOME/.xui"
mkdir -p "$XUI/data" "$XUI/cache/store_covers"
python3 - <<'PY'
import hashlib
import json
import re
import time
import urllib.request
from pathlib import Path

XUI = Path.home() / '.xui'
DATA = XUI / 'data'
COVERS = XUI / 'cache' / 'store_covers'
OUT = DATA / 'store_external.json'
BIN = XUI / 'bin'
DATA.mkdir(parents=True, exist_ok=True)
COVERS.mkdir(parents=True, exist_ok=True)

UA = {'User-Agent': 'xui-store-sync/1.0'}

def get_json(url, timeout=20):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode('utf-8', errors='ignore'))

def safe_name(text):
    return re.sub(r'[^a-zA-Z0-9._-]+', '_', str(text or 'item')).strip('_') or 'item'

def cache_cover(url, rid):
    if not url:
        return ''
    ext = '.jpg'
    low = str(url).lower()
    if '.png' in low:
        ext = '.png'
    elif '.webp' in low:
        ext = '.webp'
    name = safe_name(rid) + '_' + hashlib.sha1(str(url).encode('utf-8', errors='ignore')).hexdigest()[:10] + ext
    dst = COVERS / name
    if dst.exists() and dst.stat().st_size > 1024:
        return str(dst)
    try:
        req = urllib.request.Request(url, headers=UA)
        with urllib.request.urlopen(req, timeout=20) as r:
            data = r.read()
        if data and len(data) > 1024:
            dst.write_bytes(data)
            return str(dst)
    except Exception:
        return ''
    return ''

def flathub_items(limit=260):
    items = []
    try:
        apps = get_json('https://flathub.org/api/v2/apps')
        if not isinstance(apps, list):
            return items
        for app in apps:
            if len(items) >= limit:
                break
            app_id = str(app.get('flatpakAppId') or app.get('app_id') or '').strip()
            if not app_id:
                continue
            cats = app.get('categories') or []
            cat_names = {str(c.get('name', c)).lower() for c in cats if c}
            if 'game' not in cat_names and 'games' not in cat_names:
                continue
            name = str(app.get('name') or app_id).strip()
            summary = str(app.get('summary') or 'Flathub game').strip()
            icon = str(app.get('iconDesktopUrl') or app.get('iconMobileUrl') or '').strip()
            rid = f'flathub_{app_id}'
            cover_local = cache_cover(icon, rid)
            items.append({
                'id': rid,
                'name': name,
                'price': 0,
                'pricing': 'free',
                'category': 'Games',
                'source': 'Flathub',
                'desc': summary,
                'cover': icon,
                'cover_local': cover_local,
                'install': str(BIN / 'xui_install_flatpak_game.sh') + f' {app_id}',
                'launch': f'flatpak run {app_id}',
            })
    except Exception:
        return items
    return items

def curated_web_sources():
    # Real cards from official pages. Paid cards always redirect to official checkout.
    entries = [
        {
            'id': 'itch_holocure',
            'name': 'HoloCure (Itch.io)',
            'url': 'https://kay-yu.itch.io/holocure',
            'source': 'Itch.io',
            'cover': 'https://itch.io/favicon.ico',
            'desc': 'Real game page from Itch.io.',
            'pricing': 'free',
            'price': 0.0,
        },
        {
            'id': 'itch_deltarune',
            'name': 'DELTARUNE (Itch.io)',
            'url': 'https://tobyfox.itch.io/deltarune',
            'source': 'Itch.io',
            'cover': 'https://itch.io/favicon.ico',
            'desc': 'Real game page from Itch.io.',
            'pricing': 'free',
            'price': 0.0,
        },
        {
            'id': 'itch_horror_spotlight',
            'name': 'Itch.io Horror Spotlight',
            'url': 'https://itch.io/games/tag-horror',
            'source': 'Itch.io',
            'cover': 'https://itch.io/favicon.ico',
            'desc': 'Browse horror games on Itch.io.',
            'pricing': 'free',
            'price': 0.0,
        },
        {
            'id': 'gj_fnaf_fangames',
            'name': 'FNAF Fan Games (Game Jolt)',
            'url': 'https://gamejolt.com/games?tags=fnaf',
            'source': 'Game Jolt',
            'cover': 'https://m.gjcdn.net/assets/favicons/favicon-196x196.png',
            'desc': 'Real Game Jolt catalog filtered by FNAF.',
            'pricing': 'free',
            'price': 0.0,
        },
        {
            'id': 'gj_horror_spotlight',
            'name': 'Game Jolt Horror Spotlight',
            'url': 'https://gamejolt.com/games?tags=horror',
            'source': 'Game Jolt',
            'cover': 'https://m.gjcdn.net/assets/favicons/favicon-196x196.png',
            'desc': 'Browse horror games on Game Jolt.',
            'pricing': 'free',
            'price': 0.0,
        },
        {
            'id': 'moddb_openra',
            'name': 'OpenRA (ModDB)',
            'url': 'https://www.moddb.com/games/openra',
            'source': 'ModDB',
            'cover': 'https://www.moddb.com/favicon.ico',
            'desc': 'Real game page on ModDB.',
            'pricing': 'free',
            'price': 0.0,
        },
        {
            'id': 'moddb_xonotic',
            'name': 'Xonotic (ModDB)',
            'url': 'https://www.moddb.com/games/xonotic',
            'source': 'ModDB',
            'cover': 'https://www.moddb.com/favicon.ico',
            'desc': 'Real game page on ModDB.',
            'pricing': 'free',
            'price': 0.0,
        },
        {
            'id': 'moddb_0ad',
            'name': '0 A.D. (ModDB)',
            'url': 'https://www.moddb.com/games/0-ad',
            'source': 'ModDB',
            'cover': 'https://www.moddb.com/favicon.ico',
            'desc': 'Real game page on ModDB.',
            'pricing': 'free',
            'price': 0.0,
        },
        {
            'id': 'itch_hub_free',
            'name': 'Itch.io Free Games Hub',
            'url': 'https://itch.io/games/free',
            'source': 'Itch.io',
            'cover': 'https://itch.io/favicon.ico',
            'desc': 'Browse free games on Itch.io.',
            'pricing': 'free',
            'price': 0.0,
        },
        {
            'id': 'gamejolt_hub_games',
            'name': 'Game Jolt Games Hub',
            'url': 'https://gamejolt.com/games',
            'source': 'Game Jolt',
            'cover': 'https://m.gjcdn.net/assets/favicons/favicon-196x196.png',
            'desc': 'Browse free and paid games on Game Jolt.',
            'pricing': 'free',
            'price': 0.0,
        },
        {
            'id': 'moddb_hub_games',
            'name': 'ModDB Games Hub',
            'url': 'https://www.moddb.com/games',
            'source': 'ModDB',
            'cover': 'https://www.moddb.com/favicon.ico',
            'desc': 'Browse game pages on ModDB.',
            'pricing': 'free',
            'price': 0.0,
        },
        {
            'id': 'itch_hub_paid',
            'name': 'Itch.io Paid Games Hub',
            'url': 'https://itch.io/games/price-paid',
            'source': 'Itch.io',
            'cover': 'https://itch.io/favicon.ico',
            'desc': 'Paid games on Itch.io. Purchase happens on official pages.',
            'pricing': 'paid',
            'price': 0.0,
            'external_checkout': True,
            'purchase_url': 'https://itch.io/games/price-paid',
        },
        {
            'id': 'gamejolt_hub_market',
            'name': 'Game Jolt Marketplace',
            'url': 'https://gamejolt.com/marketplace',
            'source': 'Game Jolt',
            'cover': 'https://m.gjcdn.net/assets/favicons/favicon-196x196.png',
            'desc': 'Paid products on Game Jolt Marketplace.',
            'pricing': 'paid',
            'price': 0.0,
            'external_checkout': True,
            'purchase_url': 'https://gamejolt.com/marketplace',
        },
        {
            'id': 'steam_hub_paid',
            'name': 'Steam Paid Games Hub',
            'url': 'https://store.steampowered.com/search/?maxprice=70',
            'source': 'Steam',
            'cover': 'https://store.steampowered.com/favicon.ico',
            'desc': 'Paid games on Steam official store.',
            'pricing': 'paid',
            'price': 0.0,
            'external_checkout': True,
            'purchase_url': 'https://store.steampowered.com/search/?maxprice=70',
        },
        {
            'id': 'gog_hub_paid',
            'name': 'GOG Paid Games Hub',
            'url': 'https://www.gog.com/en/games',
            'source': 'GOG',
            'cover': 'https://www.gog.com/favicon.ico',
            'desc': 'Paid games on GOG official store.',
            'pricing': 'paid',
            'price': 0.0,
            'external_checkout': True,
            'purchase_url': 'https://www.gog.com/en/games',
        },
    ]
    out = []
    for entry in entries:
        rid = str(entry.get('id', '')).strip()
        url = str(entry.get('url', '')).strip()
        if not rid or not url:
            continue
        cover = str(entry.get('cover', '')).strip()
        cover_local = cache_cover(cover, rid)
        out.append({
            'id': rid,
            'name': str(entry.get('name', rid)),
            'price': float(max(0.0, float(entry.get('price', 0.0)))),
            'pricing': str(entry.get('pricing', 'free')).strip().lower(),
            'external_checkout': bool(entry.get('external_checkout', False)),
            'purchase_url': str(entry.get('purchase_url', '')).strip(),
            'category': 'Games',
            'source': str(entry.get('source', 'Web')),
            'desc': str(entry.get('desc', 'Real source card')),
            'cover': cover,
            'cover_local': cover_local,
            'launch': str(BIN / 'xui_browser.sh') + f' --hub {url}',
        })
    return out

items = []
items.extend(flathub_items(limit=260))
items.extend(curated_web_sources())

# Deduplicate IDs, keep first.
seen = set()
clean = []
for it in items:
    iid = str(it.get('id', '')).strip()
    if not iid or iid in seen:
        continue
    seen.add(iid)
    clean.append(it)

payload = {
    'generated_at': int(time.time()),
    'count': len(clean),
    'items': clean,
}
OUT.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding='utf-8')
print(f'External sources synced: {len(clean)} items')
PY
BASH
  chmod +x "$BIN_DIR/xui_store_sync_sources.sh"

  cat > "$GAMES_DIR/gem_match.py" <<'PY'
#!/usr/bin/env python3
import random
import sys
from PyQt5 import QtCore, QtGui, QtWidgets

COLORS = [
    QtGui.QColor('#e74c3c'),
    QtGui.QColor('#3498db'),
    QtGui.QColor('#2ecc71'),
    QtGui.QColor('#f1c40f'),
    QtGui.QColor('#9b59b6'),
    QtGui.QColor('#e67e22'),
]


class GemMatch(QtWidgets.QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle('Gem Match - XUI')
        self.setFocusPolicy(QtCore.Qt.StrongFocus)
        self.rows = 8
        self.cols = 8
        self.cell = 74
        self.pad = 20
        self.score = 0
        self.selected = None
        self.board = [[0] * self.cols for _ in range(self.rows)]
        self._generate_board()
        self.resize(self.pad * 2 + self.cols * self.cell, self.pad * 2 + self.rows * self.cell + 70)

    def _generate_board(self):
        for r in range(self.rows):
            for c in range(self.cols):
                self.board[r][c] = random.randrange(len(COLORS))
        while self._find_matches():
            self._collapse_matches(self._find_matches())

    def _find_matches(self):
        matches = set()
        for r in range(self.rows):
            streak = 1
            for c in range(1, self.cols + 1):
                prev = self.board[r][c - 1]
                cur = self.board[r][c] if c < self.cols else None
                if cur == prev:
                    streak += 1
                else:
                    if streak >= 3:
                        for k in range(c - streak, c):
                            matches.add((r, k))
                    streak = 1
        for c in range(self.cols):
            streak = 1
            for r in range(1, self.rows + 1):
                prev = self.board[r - 1][c]
                cur = self.board[r][c] if r < self.rows else None
                if cur == prev:
                    streak += 1
                else:
                    if streak >= 3:
                        for k in range(r - streak, r):
                            matches.add((k, c))
                    streak = 1
        return matches

    def _collapse_matches(self, matches):
        if not matches:
            return 0
        for (r, c) in matches:
            self.board[r][c] = -1
        removed = len(matches)
        for c in range(self.cols):
            col_vals = [self.board[r][c] for r in range(self.rows) if self.board[r][c] >= 0]
            missing = self.rows - len(col_vals)
            new_vals = [random.randrange(len(COLORS)) for _ in range(missing)] + col_vals
            for r in range(self.rows):
                self.board[r][c] = new_vals[r]
        return removed

    def _cell_at(self, pos):
        x = pos.x() - self.pad
        y = pos.y() - self.pad
        if x < 0 or y < 0:
            return None
        c = x // self.cell
        r = y // self.cell
        if 0 <= r < self.rows and 0 <= c < self.cols:
            return int(r), int(c)
        return None

    def _adjacent(self, a, b):
        return abs(a[0] - b[0]) + abs(a[1] - b[1]) == 1

    def mousePressEvent(self, e):
        cell = self._cell_at(e.pos())
        if cell is None:
            self.selected = None
            self.update()
            return
        if self.selected is None:
            self.selected = cell
            self.update()
            return
        if cell == self.selected:
            self.selected = None
            self.update()
            return
        if not self._adjacent(self.selected, cell):
            self.selected = cell
            self.update()
            return
        (r1, c1), (r2, c2) = self.selected, cell
        self.board[r1][c1], self.board[r2][c2] = self.board[r2][c2], self.board[r1][c1]
        matches = self._find_matches()
        if not matches:
            self.board[r1][c1], self.board[r2][c2] = self.board[r2][c2], self.board[r1][c1]
        else:
            while matches:
                removed = self._collapse_matches(matches)
                self.score += removed * 10
                matches = self._find_matches()
        self.selected = None
        self.update()

    def keyPressEvent(self, e):
        if e.key() in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.close()
            return
        super().keyPressEvent(e)

    def paintEvent(self, _e):
        p = QtGui.QPainter(self)
        p.fillRect(self.rect(), QtGui.QColor('#0f1720'))
        p.setRenderHint(QtGui.QPainter.Antialiasing, True)
        p.setPen(QtGui.QColor('#26384a'))
        for r in range(self.rows):
            for c in range(self.cols):
                x = self.pad + c * self.cell
                y = self.pad + r * self.cell
                rect = QtCore.QRect(x + 4, y + 4, self.cell - 8, self.cell - 8)
                idx = self.board[r][c]
                color = COLORS[idx % len(COLORS)]
                p.setBrush(color)
                p.setPen(QtGui.QPen(QtGui.QColor('#0a1118'), 2))
                p.drawRoundedRect(rect, 12, 12)
                if self.selected == (r, c):
                    p.setBrush(QtCore.Qt.NoBrush)
                    p.setPen(QtGui.QPen(QtGui.QColor('#d5f7d5'), 4))
                    p.drawRoundedRect(rect.adjusted(-2, -2, 2, 2), 12, 12)
        p.setPen(QtGui.QColor('#e8f3ff'))
        p.setFont(QtGui.QFont('Sans Serif', 14, QtGui.QFont.Bold))
        p.drawText(16, self.height() - 34, f'Score: {self.score}')
        p.drawText(190, self.height() - 34, 'Click 2 adjacent gems to swap')
        p.drawText(self.width() - 210, self.height() - 34, 'ESC = exit')
        p.end()


def main():
    app = QtWidgets.QApplication(sys.argv)
    w = GemMatch()
    try:
        w.showFullScreen()
    except Exception:
        w.show()
    sys.exit(app.exec_())


if __name__ == '__main__':
    main()
PY
  chmod +x "$GAMES_DIR/gem_match.py"

  cat > "$BIN_DIR/xui_gem_match.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
exec "$HOME/.xui/bin/xui_python.sh" "$HOME/.xui/games/gem_match.py" "$@"
BASH
  chmod +x "$BIN_DIR/xui_gem_match.sh"

  cat > "$BIN_DIR/xui_install_fnae_deps.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

as_root(){
  if [ "$(id -u)" -eq 0 ]; then "$@"; return $?; fi
  if [ "${XUI_NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
    if command -v pkexec >/dev/null 2>&1; then
      pkexec "$@" && return 0
    fi
    if command -v sudo >/dev/null 2>&1; then
      sudo -n "$@" && return 0
    fi
    echo "non-interactive root unavailable; skipping: $*" >&2
    return 1
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
    return $?
  fi
  if command -v pkexec >/dev/null 2>&1; then
    pkexec "$@"
    return $?
  fi
  echo "root privileges unavailable: $*" >&2
  return 1
}

can_noninteractive_root(){
  [ "$(id -u)" -eq 0 ] && return 0
  if command -v pkexec >/dev/null 2>&1; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || return 1
  sudo -n -v >/dev/null 2>&1
}

wait_apt(){
  local t=0
  local max_wait="${XUI_APT_WAIT_SECONDS:-180}"
  if [ "${XUI_NONINTERACTIVE:-0}" = "1" ]; then
    max_wait="${XUI_APT_WAIT_SECONDS_NONINTERACTIVE:-20}"
  fi
  while pgrep -x apt >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 || pgrep -f unattended-upgrade >/dev/null 2>&1; do
    [ "$t" -ge "$max_wait" ] && break
    sleep 2
    t=$((t+2))
  done
}

install_pkgs_best_effort(){
  local manager="$1"
  shift || true
  local p
  for p in "$@"; do
    case "$manager" in
      apt) as_root apt install -y "$p" >/dev/null 2>&1 || true ;;
      dnf) as_root dnf install -y "$p" >/dev/null 2>&1 || true ;;
      pacman) as_root pacman -S --noconfirm "$p" >/dev/null 2>&1 || true ;;
    esac
  done
}

if command -v steam-run >/dev/null 2>&1; then
  echo "steam-run already available"
  exit 0
fi

if [ "${XUI_NONINTERACTIVE:-0}" = "1" ] && ! can_noninteractive_root; then
  echo "non-interactive root unavailable; skipping runtime package install"
  exit 0
fi

if command -v apt >/dev/null 2>&1; then
  wait_apt
  as_root apt update >/dev/null 2>&1 || true
  wait_apt
  install_pkgs_best_effort apt \
    ca-certificates curl tar file xz-utils binutils \
    libc6 libstdc++6 libgcc-s1 libasound2 libx11-6 libxrandr2 libxinerama1 libxcursor1 libxi6 \
    libgl1 libglu1-mesa libpulse0 mesa-vulkan-drivers \
    steam-installer steam
elif command -v dnf >/dev/null 2>&1; then
  install_pkgs_best_effort dnf \
    ca-certificates curl tar file xz binutils \
    glibc libstdc++ libgcc alsa-lib libX11 libXrandr libXinerama libXcursor libXi \
    mesa-libGL mesa-libGLU pulseaudio-libs steam
elif command -v pacman >/dev/null 2>&1; then
  as_root pacman -Sy --noconfirm >/dev/null 2>&1 || true
  install_pkgs_best_effort pacman \
    ca-certificates curl tar file xz binutils \
    glibc gcc-libs libx11 libxrandr libxinerama libxcursor libxi mesa libpulse steam
fi

if command -v steam-run >/dev/null 2>&1; then
  echo "steam-run available"
  exit 0
fi

echo "steam-run still not available (FNAE can still fail on old glibc hosts)."
exit 0
BASH
  chmod +x "$BIN_DIR/xui_install_fnae_deps.sh"

  cat > "$BIN_DIR/xui_install_fnae.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
XUI_HOME="$HOME/.xui"
APP_HOME="$XUI_HOME/apps/fnae"
DATA_FILE="$XUI_HOME/data/fnae_paths.json"
BIN_DIR="$XUI_HOME/bin"
LINUX_MEDIAFIRE_URL="https://www.mediafire.com/file/a4q4l09vdfqzzws/Five_Nights_At_Epsteins_Linux.tar/file"
LINUX_MEDIAFIRE_DIRECT_URL="https://www.mediafire.com/download/a4q4l09vdfqzzws/Five_Nights_At_Epsteins_Linux.tar"
WINDOWS_MEDIAFIRE_URL="https://www.mediafire.com/file/6tj1rd7kmsxv4oe/Five_Nights_At_Epstein%2527s.zip/file"
WINDOWS_MEDIAFIRE_DIRECT_URL="https://www.mediafire.com/download/6tj1rd7kmsxv4oe/Five_Nights_At_Epstein%27s.zip"
mkdir -p "$APP_HOME/linux" "$APP_HOME/windows" "$XUI_HOME/data"
HOST_OS="$(uname -s 2>/dev/null || echo Linux)"
IS_LINUX=0
if [ "$HOST_OS" = "Linux" ]; then
  IS_LINUX=1
fi
LOG_DIR="$XUI_HOME/logs"
LOG_FILE="$LOG_DIR/fnae_install.log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE" >/dev/null 2>&1 || true
if command -v tee >/dev/null 2>&1; then
  exec > >(tee -a "$LOG_FILE") 2>&1
else
  exec >>"$LOG_FILE" 2>&1
fi
echo "=== FNAE install start: $(date '+%Y-%m-%d %H:%M:%S') ==="

if [ "$IS_LINUX" = "1" ] && [ -x "$BIN_DIR/xui_install_fnae_deps.sh" ]; then
  echo "[FNAE] Checking runtime dependencies..."
  if command -v timeout >/dev/null 2>&1; then
    XUI_NONINTERACTIVE=1 timeout "${XUI_FNAE_DEPS_TIMEOUT_SEC:-45}" "$BIN_DIR/xui_install_fnae_deps.sh" || true
  else
    XUI_NONINTERACTIVE=1 "$BIN_DIR/xui_install_fnae_deps.sh" || true
  fi
  echo "[FNAE] Runtime dependency step complete."
fi

find_first_existing(){
  for p in "$@"; do
    [ -f "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

find_by_name_in_dirs(){
  local name="$1"
  shift || true
  for d in "$@"; do
    [ -d "$d" ] || continue
    local found=""
    found="$(find "$d" -maxdepth 6 -type f -name "$name" 2>/dev/null | head -n1 || true)"
    if [ -n "$found" ] && [ -f "$found" ]; then
      echo "$found"
      return 0
    fi
  done
  return 1
}

is_html_file(){
  local f="$1"
  [ -f "$f" ] || return 0
  if command -v file >/dev/null 2>&1; then
    file -b "$f" 2>/dev/null | grep -Eiq 'html|xml' && return 0
  fi
  head -c 2048 "$f" 2>/dev/null | grep -Eiq '<!doctype html|<html|<head|<body|mediafire' && return 0
  return 1
}

fetch_url_to_file(){
  local url="$1"
  local out="$2"
  local ref="${3:-}"
  local max_time="${XUI_FNAE_FETCH_TIMEOUT_SEC:-180}"
  if ! [[ "$max_time" =~ ^[0-9]+$ ]] || [ "$max_time" -le 0 ]; then
    max_time=180
  fi
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$ref" ]; then
      curl -fL --retry 5 --retry-delay 2 --retry-all-errors \
        --connect-timeout 20 --max-time "$max_time" \
        -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 XUI-FNAE" \
        -e "$ref" "$url" -o "$out" >/dev/null 2>&1
    else
      curl -fL --retry 5 --retry-delay 2 --retry-all-errors \
        --connect-timeout 20 --max-time "$max_time" \
        -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 XUI-FNAE" \
        "$url" -o "$out" >/dev/null 2>&1
    fi
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    if [ -n "$ref" ]; then
      wget -q --tries=5 --waitretry=2 --timeout=25 --user-agent="Mozilla/5.0 (X11; Linux x86_64) XUI-FNAE" --referer="$ref" -O "$out" "$url"
    else
      wget -q --tries=5 --waitretry=2 --timeout=25 --user-agent="Mozilla/5.0 (X11; Linux x86_64) XUI-FNAE" -O "$out" "$url"
    fi
    return $?
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$url" "$out" "$ref" <<'PY'
import ssl
import sys
import urllib.request

url = sys.argv[1]
out = sys.argv[2]
ref = sys.argv[3] if len(sys.argv) > 3 else ''
headers = {'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 XUI-FNAE'}
if ref:
    headers['Referer'] = ref
req = urllib.request.Request(url, headers=headers)
ctx = ssl.create_default_context()
with urllib.request.urlopen(req, timeout=60, context=ctx) as r:
    payload = r.read()
if not payload:
    raise SystemExit(1)
with open(out, 'wb') as fh:
    fh.write(payload)
raise SystemExit(0)
PY
    return $?
  fi
  return 1
}

extract_mediafire_direct(){
  local html="$1"
  local direct=""
  direct="$(grep -Eo 'https:\\/\\/download[0-9]*\\.mediafire\\.com\\/[^\"]+' "$html" | head -n1 || true)"
  if [ -z "$direct" ]; then
    direct="$(grep -Eo '//download[0-9]*\\.mediafire\\.com/[^"'"'"' <>]+' "$html" | head -n1 || true)"
    [ -n "$direct" ] && direct="https:${direct}"
  fi
  if [ -z "$direct" ]; then
    direct="$(grep -Eo 'https://download[0-9]*\.mediafire\.com/[^"'"'"' <>]+' "$html" | head -n1 || true)"
  fi
  if [ -z "$direct" ]; then
    direct="$(grep -Eo 'https://[a-z0-9.-]*mediafire\.com/[^"'"'"' <>]*download[^"'"'"' <>]*' "$html" | head -n1 || true)"
  fi
  if [ -z "$direct" ]; then
    direct="$(sed -n 's/.*href="\([^"]*download[^"]*\)".*/\1/p' "$html" | grep -E '^https?://.*mediafire' | head -n1 || true)"
  fi
  if [ -z "$direct" ]; then
    direct="$(sed -n "s/.*href='\([^']*download[^']*\)'.*/\1/p" "$html" | grep -E '^https?://.*mediafire' | head -n1 || true)"
  fi
  if [ -n "$direct" ]; then
    direct="$(printf '%s' "$direct" | sed -e 's/&amp;/\&/g' -e 's#\\/#/#g')"
    printf '%s\n' "$direct"
    return 0
  fi
  return 1
}

download_from_mediafire(){
  local page_url="$1"
  local out_file="$2"
  local tmp_html tmp_dl direct
  tmp_html="$(mktemp)"
  tmp_dl="$(mktemp)"
  rm -f "$out_file"

  fetch_url_to_file "$page_url" "$tmp_html" || { rm -f "$tmp_html" "$tmp_dl"; return 1; }
  direct="$(extract_mediafire_direct "$tmp_html" || true)"
  if [ -z "$direct" ]; then
    # fallback: some links work with /download suffix
    fetch_url_to_file "${page_url%/}/download" "$tmp_html" "$page_url" || true
    direct="$(extract_mediafire_direct "$tmp_html" || true)"
  fi
  if [ -z "$direct" ]; then
    rm -f "$tmp_html" "$tmp_dl"
    return 1
  fi
  fetch_url_to_file "$direct" "$tmp_dl" "$page_url" || { rm -f "$tmp_html" "$tmp_dl"; return 1; }
  if is_html_file "$tmp_dl"; then
    local nested=""
    nested="$(extract_mediafire_direct "$tmp_dl" || true)"
    if [ -n "$nested" ] && [ "$nested" != "$direct" ]; then
      fetch_url_to_file "$nested" "$tmp_dl" "$page_url" || { rm -f "$tmp_html" "$tmp_dl"; return 1; }
    fi
  fi
  if is_html_file "$tmp_dl"; then
    rm -f "$tmp_html" "$tmp_dl"
    return 1
  fi
  if [ ! -s "$tmp_dl" ]; then
    rm -f "$tmp_html" "$tmp_dl"
    return 1
  fi
  mv -f "$tmp_dl" "$out_file"
  rm -f "$tmp_html"
  return 0
}

download_from_mediafire_python(){
  local page_url="$1"
  local out_file="$2"
  command -v python3 >/dev/null 2>&1 || return 1
  rm -f "$out_file" >/dev/null 2>&1 || true
  python3 - "$page_url" "$out_file" <<'PY'
import html
import re
import ssl
import sys
import urllib.parse
import urllib.request

page_url = sys.argv[1]
out_file = sys.argv[2]
headers = {'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 XUI-FNAE'}
ctx = ssl.create_default_context()

def fetch(url, referer=''):
    h = dict(headers)
    if referer:
        h['Referer'] = referer
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=60, context=ctx) as r:
        return r.read()

raw = fetch(page_url)
txt = raw.decode('utf-8', 'ignore')

m = re.search(r'id=["\']downloadButton["\'][^>]*href=["\']([^"\']+)', txt, re.IGNORECASE)
if not m:
    m = re.search(r'https?://download[0-9]*\.mediafire\.com/[^\s"\'<>]+', txt, re.IGNORECASE)
if not m:
    m = re.search(r'https:\\/\\/download[0-9]*\\.mediafire\\.com\\/[^\s"\'<>]+', txt, re.IGNORECASE)
if not m:
    raise SystemExit(1)

raw_direct = m.group(1) if (getattr(m, 'lastindex', 0) or 0) >= 1 else m.group(0)
direct = html.unescape(raw_direct).replace('\\/', '/')
if direct.startswith('//'):
    direct = 'https:' + direct
if direct.startswith('/'):
    direct = urllib.parse.urljoin(page_url, direct)

payload = fetch(direct, page_url)
head = payload[:4096].lower()
if b'<html' in head or b'<!doctype html' in head:
    raise SystemExit(2)
if not payload:
    raise SystemExit(3)

with open(out_file, 'wb') as fh:
    fh.write(payload)
raise SystemExit(0)
PY
  return $?
}

download_mediafire_archive(){
  local out_file="$1"
  local validator="$2"
  shift 2
  local src=""
  rm -f "$out_file" >/dev/null 2>&1 || true
  for src in "$@"; do
    [ -n "$src" ] || continue
    echo "[FNAE] Download attempt: $src"
    if fetch_url_to_file "$src" "$out_file" "$src" && [ -s "$out_file" ] && ! is_html_file "$out_file" && "$validator" "$out_file"; then
      return 0
    fi
    rm -f "$out_file" >/dev/null 2>&1 || true
  done
  for src in "$@"; do
    [ -n "$src" ] || continue
    echo "[FNAE] MediaFire parse attempt: $src"
    if download_from_mediafire "$src" "$out_file" && "$validator" "$out_file"; then
      return 0
    fi
    rm -f "$out_file" >/dev/null 2>&1 || true
  done
  for src in "$@"; do
    [ -n "$src" ] || continue
    echo "[FNAE] Python MediaFire attempt: $src"
    if download_from_mediafire_python "$src" "$out_file" && "$validator" "$out_file"; then
      return 0
    fi
    rm -f "$out_file" >/dev/null 2>&1 || true
  done
  return 1
}

validate_tar(){
  local f="$1"
  [ -f "$f" ] || return 1
  tar -tf "$f" >/dev/null 2>&1
}

validate_zip(){
  local f="$1"
  [ -f "$f" ] || return 1
  if command -v unzip >/dev/null 2>&1; then
    unzip -tq "$f" >/dev/null 2>&1
    return $?
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$f" <<'PY'
import sys, zipfile
try:
    with zipfile.ZipFile(sys.argv[1], 'r') as zf:
        zf.testzip()
except Exception:
    raise SystemExit(1)
raise SystemExit(0)
PY
    return $?
  fi
  return 0
}

find_linux_executable(){
  local root="$1"
  [ -d "$root" ] || return 1

  is_elf(){
    local f="$1"
    [ -f "$f" ] || return 1
    LC_ALL=C head -c 4 "$f" 2>/dev/null | grep -q $'^\x7fELF'
  }

  # 1) Common Unity/Linux artifacts.
  local exe=""
  exe="$(find "$root" -maxdepth 8 -type f \( -name '*.x86_64' -o -name '*.x86' -o -name '*.AppImage' \) | head -n1 || true)"
  if [ -n "$exe" ] && [ -f "$exe" ]; then
    chmod +x "$exe" >/dev/null 2>&1 || true
    echo "$exe"
    return 0
  fi

  # 2) Unity convention: <GameName> executable + <GameName>_Data directory.
  local data_dir base cand
  while IFS= read -r data_dir; do
    [ -n "$data_dir" ] || continue
    base="${data_dir%_Data}"
    for cand in "$base" "$base.x86_64" "$base.x86"; do
      if [ -f "$cand" ]; then
        chmod +x "$cand" >/dev/null 2>&1 || true
        echo "$cand"
        return 0
      fi
    done
  done < <(find "$root" -maxdepth 8 -type d -name '*_Data' 2>/dev/null)

  # 3) Fallback: executable files that look like game launchers.
  exe="$(find "$root" -maxdepth 8 -type f \
    ! -name '*.so' ! -name '*.dll' ! -name '*.pdb' \
    ! -name 'UnityCrashHandler*' ! -name '*.exe' \
    -perm -u+x | head -n1 || true)"
  if [ -n "$exe" ] && [ -f "$exe" ]; then
    chmod +x "$exe" >/dev/null 2>&1 || true
    echo "$exe"
    return 0
  fi

  # 4) Fallback: any ELF binary, even if it was extracted without +x bit.
  while IFS= read -r exe; do
    [ -n "$exe" ] || continue
    if is_elf "$exe"; then
      chmod +x "$exe" >/dev/null 2>&1 || true
      echo "$exe"
      return 0
    fi
  done < <(find "$root" -maxdepth 8 -type f \
    ! -name '*.so' ! -name '*.dll' ! -name '*.pdb' \
    ! -name 'UnityCrashHandler*' ! -name '*.exe' 2>/dev/null)
  return 1
}

tar_candidates=(
  "$HOME/.xui/cache/games/Five Nights At Epsteins Linux.tar"
  "$HOME/.xui/cache/games/Five_Nights_At_Epsteins_Linux.tar"
  "$HOME/.xui/GAMES/Five Nights At Epsteins Linux.tar"
  "$HOME/.xui/GAMES/Five_Nights_At_Epsteins_Linux.tar"
  "$PWD/GAMES/Five Nights At Epsteins Linux.tar"
  "$PWD/GAMES/Five_Nights_At_Epsteins_Linux.tar"
  "$PWD/Five Nights At Epsteins Linux.tar"
  "$PWD/Five_Nights_At_Epsteins_Linux.tar"
  "$HOME/GAMES/Five Nights At Epsteins Linux.tar"
  "$HOME/GAMES/Five_Nights_At_Epsteins_Linux.tar"
  "$HOME/Downloads/Five Nights At Epsteins Linux.tar"
  "$HOME/Downloads/Five_Nights_At_Epsteins_Linux.tar"
  "$HOME/Desktop/Five Nights At Epsteins Linux.tar"
  "$HOME/Desktop/Five_Nights_At_Epsteins_Linux.tar"
  "/mnt/c/Users/Usuario/Downloads/xui/xui/GAMES/Five Nights At Epsteins Linux.tar"
  "/mnt/c/Users/Usuario/Downloads/xui/xui/GAMES/Five_Nights_At_Epsteins_Linux.tar"
  "/mnt/c/Users/Usuario/Downloads/Five Nights At Epsteins Linux.tar"
  "/mnt/c/Users/Usuario/Downloads/Five_Nights_At_Epsteins_Linux.tar"
  "/mnt/c/Users/$USER/Downloads/xui/xui/GAMES/Five Nights At Epsteins Linux.tar"
  "/mnt/c/Users/$USER/Downloads/xui/xui/GAMES/Five_Nights_At_Epsteins_Linux.tar"
  "/mnt/c/Users/$USER/Downloads/Five Nights At Epsteins Linux.tar"
  "/mnt/c/Users/$USER/Downloads/Five_Nights_At_Epsteins_Linux.tar"
)
zip_candidates=(
  "$HOME/.xui/cache/games/Five Nights At Epstein's.zip"
  "$HOME/.xui/cache/games/Five_Nights_At_Epstein's.zip"
  "$HOME/.xui/GAMES/Five Nights At Epstein's.zip"
  "$HOME/.xui/GAMES/Five_Nights_At_Epstein's.zip"
  "$PWD/GAMES/Five Nights At Epstein's.zip"
  "$PWD/GAMES/Five_Nights_At_Epstein's.zip"
  "$PWD/Five Nights At Epstein's.zip"
  "$PWD/Five_Nights_At_Epstein's.zip"
  "$HOME/GAMES/Five Nights At Epstein's.zip"
  "$HOME/GAMES/Five_Nights_At_Epstein's.zip"
  "$HOME/Downloads/Five Nights At Epstein's.zip"
  "$HOME/Downloads/Five_Nights_At_Epstein's.zip"
  "$HOME/Desktop/Five Nights At Epstein's.zip"
  "$HOME/Desktop/Five_Nights_At_Epstein's.zip"
  "/mnt/c/Users/Usuario/Downloads/xui/xui/GAMES/Five Nights At Epstein's.zip"
  "/mnt/c/Users/Usuario/Downloads/xui/xui/GAMES/Five_Nights_At_Epstein's.zip"
  "/mnt/c/Users/Usuario/Downloads/Five Nights At Epstein's.zip"
  "/mnt/c/Users/Usuario/Downloads/Five_Nights_At_Epstein's.zip"
  "/mnt/c/Users/$USER/Downloads/xui/xui/GAMES/Five Nights At Epstein's.zip"
  "/mnt/c/Users/$USER/Downloads/xui/xui/GAMES/Five_Nights_At_Epstein's.zip"
  "/mnt/c/Users/$USER/Downloads/Five Nights At Epstein's.zip"
  "/mnt/c/Users/$USER/Downloads/Five_Nights_At_Epstein's.zip"
)

TAR_SRC="$(find_first_existing "${tar_candidates[@]}" || true)"
ZIP_SRC="$(find_first_existing "${zip_candidates[@]}" || true)"
if [ -n "$TAR_SRC" ] && ! validate_tar "$TAR_SRC"; then
  echo "Ignoring invalid TAR candidate: $TAR_SRC"
  TAR_SRC=""
fi
if [ -n "$ZIP_SRC" ] && ! validate_zip "$ZIP_SRC"; then
  echo "Ignoring invalid ZIP candidate: $ZIP_SRC"
  ZIP_SRC=""
fi

# Fallback scan by filename in common roots if direct candidates failed.
if [ -z "$TAR_SRC" ]; then
  TAR_SRC="$(find_by_name_in_dirs "Five Nights At Epsteins Linux.tar" \
    "$HOME/.xui/cache/games" "$HOME/.xui/GAMES" "$PWD" "$HOME/Downloads" "$HOME/Desktop" "$HOME/GAMES" \
    "/mnt/c/Users/Usuario/Downloads/xui/xui/GAMES" "/mnt/c/Users/Usuario/Downloads" \
    "/mnt/c/Users/$USER/Downloads/xui/xui/GAMES" "/mnt/c/Users/$USER/Downloads" \
    2>/dev/null || true)"
fi
if [ -z "$TAR_SRC" ]; then
  TAR_SRC="$(find_by_name_in_dirs "Five_Nights_At_Epsteins_Linux.tar" \
    "$HOME/.xui/cache/games" "$HOME/.xui/GAMES" "$PWD" "$HOME/Downloads" "$HOME/Desktop" "$HOME/GAMES" \
    "/mnt/c/Users/Usuario/Downloads/xui/xui/GAMES" "/mnt/c/Users/Usuario/Downloads" \
    "/mnt/c/Users/$USER/Downloads/xui/xui/GAMES" "/mnt/c/Users/$USER/Downloads" \
    2>/dev/null || true)"
fi
if [ -z "$ZIP_SRC" ]; then
  ZIP_SRC="$(find_by_name_in_dirs "Five Nights At Epstein's.zip" \
    "$HOME/.xui/cache/games" "$HOME/.xui/GAMES" "$PWD" "$HOME/Downloads" "$HOME/Desktop" "$HOME/GAMES" \
    "/mnt/c/Users/Usuario/Downloads/xui/xui/GAMES" "/mnt/c/Users/Usuario/Downloads" \
    "/mnt/c/Users/$USER/Downloads/xui/xui/GAMES" "/mnt/c/Users/$USER/Downloads" \
    2>/dev/null || true)"
fi
if [ -z "$ZIP_SRC" ]; then
  ZIP_SRC="$(find_by_name_in_dirs "Five_Nights_At_Epstein's.zip" \
    "$HOME/.xui/cache/games" "$HOME/.xui/GAMES" "$PWD" "$HOME/Downloads" "$HOME/Desktop" "$HOME/GAMES" \
    "/mnt/c/Users/Usuario/Downloads/xui/xui/GAMES" "/mnt/c/Users/Usuario/Downloads" \
    "/mnt/c/Users/$USER/Downloads/xui/xui/GAMES" "/mnt/c/Users/$USER/Downloads" \
    2>/dev/null || true)"
fi

mkdir -p "$XUI_HOME/cache/games"
if [ -z "$TAR_SRC" ]; then
  DL_TAR="$XUI_HOME/cache/games/Five Nights At Epsteins Linux.tar"
  if download_mediafire_archive "$DL_TAR" validate_tar \
    "$LINUX_MEDIAFIRE_DIRECT_URL" \
    "$LINUX_MEDIAFIRE_URL" \
    "${LINUX_MEDIAFIRE_URL%/file}/download"; then
    TAR_SRC="$DL_TAR"
    echo "Downloaded FNAE Linux archive from MediaFire."
  else
    rm -f "$DL_TAR" >/dev/null 2>&1 || true
  fi
fi
if [ "$IS_LINUX" = "0" ] && [ -z "$ZIP_SRC" ]; then
  DL_ZIP="$XUI_HOME/cache/games/Five Nights At Epstein's.zip"
  if download_mediafire_archive "$DL_ZIP" validate_zip \
    "$WINDOWS_MEDIAFIRE_DIRECT_URL" \
    "$WINDOWS_MEDIAFIRE_URL" \
    "${WINDOWS_MEDIAFIRE_URL%/file}/download"; then
    ZIP_SRC="$DL_ZIP"
    echo "Downloaded FNAE Windows archive from MediaFire."
  else
    rm -f "$DL_ZIP" >/dev/null 2>&1 || true
  fi
fi

if [ "$IS_LINUX" = "1" ] && [ -z "$TAR_SRC" ]; then
  echo "FNAE Linux archive was not found or download failed."
  echo "Required Linux URL:"
  echo "  $LINUX_MEDIAFIRE_URL"
  exit 1
fi

if [ -z "$TAR_SRC" ] && [ -z "$ZIP_SRC" ]; then
  echo "FNAE archives not found."
  echo "Expected: Five Nights At Epsteins Linux.tar and/or Five Nights At Epstein's.zip"
  echo "Checked common locations and MediaFire download fallback."
  exit 1
fi

# Cache detected archives inside ~/.xui so store installation works after purchase.
if [ -n "$TAR_SRC" ] && [ -f "$TAR_SRC" ]; then
  cp -f "$TAR_SRC" "$XUI_HOME/cache/games/Five Nights At Epsteins Linux.tar" >/dev/null 2>&1 || true
fi
if [ -n "$ZIP_SRC" ] && [ -f "$ZIP_SRC" ]; then
  cp -f "$ZIP_SRC" "$XUI_HOME/cache/games/Five Nights At Epstein's.zip" >/dev/null 2>&1 || true
fi

if [ -n "$TAR_SRC" ]; then
  rm -rf "$APP_HOME/linux"
  mkdir -p "$APP_HOME/linux"
  tar -xf "$TAR_SRC" -C "$APP_HOME/linux"
fi

if [ "$IS_LINUX" = "0" ] && [ -n "$ZIP_SRC" ]; then
  rm -rf "$APP_HOME/windows"
  mkdir -p "$APP_HOME/windows"
  if command -v unzip >/dev/null 2>&1; then
    unzip -oq "$ZIP_SRC" -d "$APP_HOME/windows"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$ZIP_SRC" "$APP_HOME/windows" <<'PY'
import sys, zipfile
src = sys.argv[1]
dst = sys.argv[2]
with zipfile.ZipFile(src, 'r') as zf:
    zf.extractall(dst)
PY
  else
    tar -xf "$ZIP_SRC" -C "$APP_HOME/windows"
  fi
fi

LINUX_EXE="$(find_linux_executable "$APP_HOME/linux" || true)"
WIN_EXE="$(find "$APP_HOME/windows" -maxdepth 5 -type f -iname 'Five Nights At Epstein*.exe' | head -n1 || true)"
if [ -z "$WIN_EXE" ]; then
  WIN_EXE="$(find "$APP_HOME/windows" -maxdepth 5 -type f -iname '*.exe' ! -iname 'UnityCrashHandler*.exe' | head -n1 || true)"
fi
if [ "$IS_LINUX" = "1" ]; then
  # In Linux installs we do not want Windows fallback to be selected by accident.
  WIN_EXE=""
fi

cat > "$DATA_FILE" <<JSON
{
  "linux_exe": "$(printf '%s' "$LINUX_EXE")",
  "windows_exe": "$(printf '%s' "$WIN_EXE")",
  "installed_from_tar": $( [ -n "$TAR_SRC" ] && echo true || echo false ),
  "installed_from_zip": $( [ -n "$ZIP_SRC" ] && echo true || echo false )
}
JSON

echo "FNAE installed."
echo "Linux executable: ${LINUX_EXE:-not found}"
echo "Windows executable: ${WIN_EXE:-not found/disabled on Linux}"
if [ "$IS_LINUX" = "1" ] && [ -z "$LINUX_EXE" ]; then
  echo "FNAE install completed but Linux executable was not detected."
  echo "Check extracted files in: $APP_HOME/linux"
  exit 1
fi
BASH
  chmod +x "$BIN_DIR/xui_install_fnae.sh"

  # Cache local FNAE archives from project GAMES folder so store purchases can install reliably.
  mkdir -p "$XUI_DIR/cache/games"
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for src in \
    "$script_dir/GAMES/Five Nights At Epsteins Linux.tar" \
    "$PWD/GAMES/Five Nights At Epsteins Linux.tar" \
    "/mnt/c/Users/Usuario/Downloads/xui/xui/GAMES/Five Nights At Epsteins Linux.tar"; do
    if [ -f "$src" ]; then
      cp -f "$src" "$XUI_DIR/cache/games/Five Nights At Epsteins Linux.tar" || true
      info "Cached FNAE Linux archive: $src"
      break
    fi
  done
  for src in \
    "$script_dir/GAMES/Five Nights At Epstein's.zip" \
    "$PWD/GAMES/Five Nights At Epstein's.zip" \
    "/mnt/c/Users/Usuario/Downloads/xui/xui/GAMES/Five Nights At Epstein's.zip"; do
    if [ -f "$src" ]; then
      cp -f "$src" "$XUI_DIR/cache/games/Five Nights At Epstein's.zip" || true
      info "Cached FNAE Windows archive: $src"
      break
    fi
  done

  cat > "$BIN_DIR/xui_run_fnae.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
XUI_HOME="$HOME/.xui"
APP_HOME="$XUI_HOME/apps/fnae"
DATA_FILE="$XUI_HOME/data/fnae_paths.json"
BIN_DIR="$XUI_HOME/bin"
PID_FILE="$XUI_HOME/data/active_game.pid"
HOST_OS="$(uname -s 2>/dev/null || echo Linux)"
IS_LINUX=0
[ "$HOST_OS" = "Linux" ] && IS_LINUX=1
ALLOW_WIN_ON_LINUX="${XUI_FNAE_ALLOW_WINDOWS_ON_LINUX:-0}"
USE_STEAM_RUNTIME="${XUI_FNAE_USE_STEAM_RUNTIME:-auto}"
DEPS_SCRIPT="$BIN_DIR/xui_install_fnae_deps.sh"
CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
  shift || true
fi

read_json_field(){
  local field="$1"
  python3 - "$DATA_FILE" "$field" <<'PY'
import json, sys
path = sys.argv[1]
field = sys.argv[2]
try:
    data = json.load(open(path, 'r', encoding='utf-8'))
except Exception:
    print('')
    raise SystemExit(0)
print(str(data.get(field, '')))
PY
}

find_linux_executable(){
  local root="${1:-$APP_HOME/linux}"
  [ -d "$root" ] || return 1
  is_elf(){
    local f="$1"
    [ -f "$f" ] || return 1
    LC_ALL=C head -c 4 "$f" 2>/dev/null | grep -q $'^\x7fELF'
  }
  local exe=""
  exe="$(find "$root" -maxdepth 8 -type f \( -name '*.x86_64' -o -name '*.x86' -o -name '*.AppImage' \) | head -n1 || true)"
  if [ -n "$exe" ] && [ -f "$exe" ]; then
    echo "$exe"
    return 0
  fi
  while IFS= read -r data_dir; do
    [ -n "$data_dir" ] || continue
    local base="${data_dir%_Data}"
    for exe in "$base" "$base.x86_64" "$base.x86"; do
      if [ -f "$exe" ]; then
        echo "$exe"
        return 0
      fi
    done
  done < <(find "$root" -maxdepth 8 -type d -name '*_Data' 2>/dev/null)
  exe="$(find "$root" -maxdepth 8 -type f \
    ! -name '*.so' ! -name '*.dll' ! -name '*.pdb' \
    ! -name 'UnityCrashHandler*' ! -name '*.exe' \
    -perm -u+x | head -n1 || true)"
  if [ -n "$exe" ] && [ -f "$exe" ]; then
    echo "$exe"
    return 0
  fi
  while IFS= read -r exe; do
    [ -n "$exe" ] || continue
    if is_elf "$exe"; then
      echo "$exe"
      return 0
    fi
  done < <(find "$root" -maxdepth 8 -type f \
    ! -name '*.so' ! -name '*.dll' ! -name '*.pdb' \
    ! -name 'UnityCrashHandler*' ! -name '*.exe' 2>/dev/null)
  return 1
}

version_gt(){
  local a="${1:-0}"
  local b="${2:-0}"
  [ "$a" = "$b" ] && return 1
  [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" = "$a" ]
}

host_glibc_version(){
  local v=""
  v="$(ldd --version 2>/dev/null | head -n1 | grep -Eo '[0-9]+\.[0-9]+' | head -n1 || true)"
  printf '%s\n' "$v"
}

required_glibc_version(){
  local exe="$1"
  command -v strings >/dev/null 2>&1 || return 1
  local dir req=""
  dir="$(dirname "$exe")"
  if [ -f "$dir/UnityPlayer.so" ]; then
    req="$(strings "$exe" "$dir/UnityPlayer.so" 2>/dev/null | grep -Eo 'GLIBC_[0-9]+\.[0-9]+' | sed 's/^GLIBC_//' | sort -V | tail -n1 || true)"
  else
    req="$(strings "$exe" 2>/dev/null | grep -Eo 'GLIBC_[0-9]+\.[0-9]+' | sed 's/^GLIBC_//' | sort -V | tail -n1 || true)"
  fi
  [ -n "$req" ] || return 1
  printf '%s\n' "$req"
}

needs_runtime_for_glibc(){
  local exe="$1"
  local host req
  host="$(host_glibc_version || true)"
  req="$(required_glibc_version "$exe" || true)"
  [ -n "$host" ] || return 1
  [ -n "$req" ] || return 1
  version_gt "$req" "$host"
}

ensure_fnae_runtime_deps(){
  [ -x "$DEPS_SCRIPT" ] || return 1
  "$DEPS_SCRIPT" || true
  command -v steam-run >/dev/null 2>&1
}

if [ "$CHECK_ONLY" = "0" ] && [ ! -f "$DATA_FILE" ]; then
  "$BIN_DIR/xui_install_fnae.sh" || true
fi

LINUX_EXE=""
WIN_EXE=""
if [ -f "$DATA_FILE" ]; then
  LINUX_EXE="$(read_json_field linux_exe)"
  WIN_EXE="$(read_json_field windows_exe)"
fi
if [ -z "$LINUX_EXE" ] || [ ! -f "$LINUX_EXE" ]; then
  LINUX_EXE="$(find_linux_executable "$APP_HOME/linux" || true)"
fi

# On Linux, force a Linux reinstall once if no native executable was detected.
if [ "$CHECK_ONLY" = "0" ] && [ "$IS_LINUX" = "1" ] && { [ -z "$LINUX_EXE" ] || [ ! -f "$LINUX_EXE" ]; }; then
  "$BIN_DIR/xui_install_fnae.sh" || true
  if [ -f "$DATA_FILE" ]; then
    LINUX_EXE="$(read_json_field linux_exe)"
    WIN_EXE="$(read_json_field windows_exe)"
  fi
fi

if [ "$CHECK_ONLY" = "1" ]; then
  if [ "$IS_LINUX" = "1" ]; then
    [ -n "$LINUX_EXE" ] && [ -f "$LINUX_EXE" ] && exit 0
    exit 1
  fi
  [ -n "$WIN_EXE" ] && [ -f "$WIN_EXE" ] && exit 0
  exit 1
fi

launch_and_wait(){
  local run_dir="$1"
  shift
  if [ -n "$run_dir" ] && [ -d "$run_dir" ]; then
    (
      cd "$run_dir" || exit 1
      "$@"
    ) &
  else
    "$@" &
  fi
  local pid=$!
  mkdir -p "$(dirname "$PID_FILE")"
  printf '%s\n' "$pid" > "$PID_FILE"
  local rc=0
  wait "$pid" || rc=$?
  if [ -f "$PID_FILE" ] && [ "$(cat "$PID_FILE" 2>/dev/null || true)" = "$pid" ]; then
    rm -f "$PID_FILE"
  fi
  return $rc
}

if [ -n "$LINUX_EXE" ] && [ -f "$LINUX_EXE" ]; then
  chmod +x "$LINUX_EXE" || true
  if [ "$IS_LINUX" = "1" ] && [ "$USE_STEAM_RUNTIME" != "0" ]; then
    if [ "$USE_STEAM_RUNTIME" = "1" ] || needs_runtime_for_glibc "$LINUX_EXE"; then
      if ! command -v steam-run >/dev/null 2>&1; then
        ensure_fnae_runtime_deps || true
      fi
      if command -v steam-run >/dev/null 2>&1; then
        launch_and_wait "$(dirname "$LINUX_EXE")" steam-run "$LINUX_EXE" "$@"
        exit $?
      fi
      host_glibc="$(host_glibc_version || true)"
      req_glibc="$(required_glibc_version "$LINUX_EXE" || true)"
      echo "FNAE requires newer runtime (glibc ${req_glibc:-unknown}, host ${host_glibc:-unknown})."
      echo "steam-run is not available."
      echo "Run dependency installer:"
      echo "  $DEPS_SCRIPT"
      exit 1
    fi
  fi
  launch_and_wait "$(dirname "$LINUX_EXE")" "$LINUX_EXE" "$@"
  exit $?
fi

if [ "$IS_LINUX" = "1" ] && [ "${ALLOW_WIN_ON_LINUX}" != "1" ]; then
  echo "FNAE Linux build was not detected."
  echo "Windows fallback is disabled on Linux to avoid crashes."
  echo "Reinstall Linux build:"
  echo "  $BIN_DIR/xui_install_fnae.sh"
  echo "If you still want to force Wine fallback:"
  echo "  XUI_FNAE_ALLOW_WINDOWS_ON_LINUX=1 $BIN_DIR/xui_run_fnae.sh"
  exit 1
fi

if [ -n "$WIN_EXE" ] && [ -f "$WIN_EXE" ]; then
  launch_and_wait "$(dirname "$WIN_EXE")" "$BIN_DIR/xui_wine_run.sh" "$WIN_EXE" "$@"
  exit $?
fi

echo "FNAE executable not found. Run installer:"
echo "  $BIN_DIR/xui_install_fnae.sh"
exit 1
BASH
  chmod +x "$BIN_DIR/xui_run_fnae.sh"

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
DefaultDependencies=no
After=graphical-session-pre.target
Before=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=%h/.xui/bin/xui_startup_and_dashboard.sh
# Ensure a display and runtime dir are available for GUI startup under systemd --user
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/%U
Restart=on-failure
RestartSec=0.5
Nice=-8
IOSchedulingClass=best-effort
IOSchedulingPriority=0
OOMScoreAdjust=-700
CPUSchedulingPolicy=other
Environment=XUI_SKIP_STARTUP_AUDIO=1

[Install]
WantedBy=graphical-session.target
UNIT

  cat > "$SYSTEMD_USER_DIR/xui-joy.service" <<UNIT
[Unit]
Description=XUI Joy Listener (user)
After=graphical-session-pre.target
PartOf=graphical-session.target

[Service]
Type=simple
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=XAUTHORITY=%h/.Xauthority
EnvironmentFile=-%h/.xui/data/controller_profile.env
ExecStart=%h/.xui/bin/xui_python.sh %h/.xui/bin/xui_joy_listener.py
Restart=on-failure
RestartSec=0.4

[Install]
WantedBy=graphical-session.target
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
X-GNOME-Autostart-enabled=false
Hidden=true
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
# and create a startup wrapper that plays startup.mp4 once before dashboard.
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/xui_startup_and_dashboard.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

TARGET_HOME="${XUI_USER_HOME:-$HOME}"
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    if command -v getent >/dev/null 2>&1; then
        _su_home="$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)"
        [ -n "${_su_home:-}" ] && TARGET_HOME="$_su_home"
    elif [ -d "/home/$SUDO_USER" ]; then
        TARGET_HOME="/home/$SUDO_USER"
    fi
fi

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        if sudo -n "$0" "$@"; then
            exit 0
        fi
    fi
    echo "[WARN] Passwordless sudo is required for dashboard launch." >&2
    echo "[WARN] Re-run installer/update to configure /etc/sudoers.d/xui-dashboard-\$USER." >&2
    exit 1
fi

export HOME="$TARGET_HOME"
export USER="${SUDO_USER:-${USER:-$(id -un)}}"
export LOGNAME="${SUDO_USER:-${LOGNAME:-$USER}}"
ASSETS_DIR="$TARGET_HOME/.xui/assets"
DASH_SCRIPT="$TARGET_HOME/.xui/dashboard/pyqt_dashboard_improved.py"
SETUP_SCRIPT="$TARGET_HOME/.xui/bin/xui_first_setup.py"
SETUP_STATE="$TARGET_HOME/.xui/data/setup_state.json"
PY_RUNNER="$TARGET_HOME/.xui/bin/xui_python.sh"
LOCK_FILE="$TARGET_HOME/.xui/data/dashboard-session.lock"

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

mkdir -p "$TARGET_HOME/.xui/data" "$TARGET_HOME/.xui/logs" "$ASSETS_DIR"

# Avoid duplicate dashboard instances when desktop autostart + systemd start at the same login.
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        info "Dashboard already running in this session (lock active)"
        exit 0
    fi
else
    if pgrep -u "$(id -u)" -f 'pyqt_dashboard_improved.py' >/dev/null 2>&1; then
        info "Dashboard already running in this session"
        exit 0
    fi
fi

# Run first setup wizard once (or force with XUI_FORCE_SETUP=1)
if [ "${XUI_FORCE_SETUP:-0}" = "1" ] || [ ! -s "$SETUP_STATE" ]; then
    if [ -f "$SETUP_SCRIPT" ]; then
        info "Running first setup wizard"
        run_python "$SETUP_SCRIPT" || warn "First setup ended with non-zero status"
    else
        warn "Setup wizard not found: $SETUP_SCRIPT"
    fi
fi

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

# Play startup video (blocking) if present
if [ -f "$ASSETS_DIR/startup.mp4" ]; then
    info "Playing startup video"
    play_video "$ASSETS_DIR/startup.mp4" || true
fi

# Finally start the dashboard
info "Launching dashboard"
if [ ! -f "$DASH_SCRIPT" ]; then
    warn "Dashboard script not found: $DASH_SCRIPT"
    exit 1
fi
if [ -x "$PY_RUNNER" ]; then
    export XUI_SKIP_STARTUP_VIDEO=1
    exec "$PY_RUNNER" "$DASH_SCRIPT"
fi
export XUI_SKIP_STARTUP_VIDEO=1
exec python3 "$DASH_SCRIPT"
SH
chmod +x "$BIN_DIR/xui_startup_and_dashboard.sh"


# If startup media not provided, try to generate them from the embedded/copyed logo using ffmpeg (best-effort)
if [ ! -f "$ASSETS_DIR/startup.mp4" ] && command -v ffmpeg >/dev/null 2>&1 && [ -f "$ASSETS_DIR/logo.png" ]; then
    info "Generating $ASSETS_DIR/startup.mp4 from logo (ffmpeg detected)"
    ffmpeg -y -loop 1 -i "$ASSETS_DIR/logo.png" -c:v libx264 -t 3 -pix_fmt yuv420p "$ASSETS_DIR/startup.mp4" >/dev/null 2>&1 || warn "ffmpeg failed to generate startup.mp4"
fi

# startup.mp3 is intentionally not auto-generated. Startup uses video only.
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
X-GNOME-Autostart-enabled=false
Hidden=true
NoDisplay=false
Categories=Utility;
EOF

# Write systemd user service
cat > "$SYSTEMD_USER_DIR/$SERVICE_NAME" <<EOF
[Unit]
Description=XUI GUI Dashboard (user service)
DefaultDependencies=no
After=graphical-session-pre.target
Before=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=$START_WRAPPER
Restart=on-failure
RestartSec=0.5
Nice=-8
IOSchedulingClass=best-effort
IOSchedulingPriority=0
OOMScoreAdjust=-700
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=$RUNTIME_DIR
Environment=XUI_SKIP_STARTUP_AUDIO=1

[Install]
WantedBy=graphical-session.target
EOF

OPENBOX_FILE="$HOME/.config/openbox/autostart"
XPROFILE_FILE="$HOME/.xprofile"
mkdir -p "$(dirname "$OPENBOX_FILE")"
touch "$OPENBOX_FILE" "$XPROFILE_FILE"
# Remove legacy duplicate launch hooks to avoid startup double-run.
sed -i '/xui_startup_and_dashboard.sh/d' "$OPENBOX_FILE" 2>/dev/null || true
sed -i '/xui_startup_and_dashboard.sh/d' "$XPROFILE_FILE" 2>/dev/null || true

# Reload user systemd and enable service
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload || true
    systemctl --user enable --now "$SERVICE_NAME" || {
        echo "Failed to enable systemd user service; you can enable it with: systemctl --user enable --now $SERVICE_NAME"
    }
else
    echo "systemctl not found; enable ~/.config/autostart/xui-dashboard.desktop manually."
fi

# Configure passwordless sudo for dashboard wrapper (no prompt at launch time)
if command -v sudo >/dev/null 2>&1; then
    SUDOERS_FILE="/etc/sudoers.d/xui-dashboard-$USER"
    TMPF="$(mktemp)"
    printf '%s ALL=(root) NOPASSWD: %s, %s\n' "$USER" "$START_WRAPPER" "$XUI_HOME/bin/xui_start.sh" > "$TMPF"
    if sudo -n install -m 0440 "$TMPF" "$SUDOERS_FILE" >/dev/null 2>&1; then
        if command -v visudo >/dev/null 2>&1; then
            sudo -n visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1 || true
        fi
        echo "Configured passwordless sudo for dashboard launcher: $SUDOERS_FILE"
    else
        echo "Warning: could not configure $SUDOERS_FILE with sudo -n."
    fi
    rm -f "$TMPF"
fi

# Feedback
echo "Installed autostart .desktop to $AUTOSTART_DIR/$DESKTOP_FILE_NAME"
echo "Installed systemd user unit to $SYSTEMD_USER_DIR/$SERVICE_NAME (enabled)."
echo "Cleaned legacy Openbox/X profile startup hooks to prevent duplicate launches."

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
PARTS=(data bin dashboard casino games assets)
EXISTING=()
for part in "${PARTS[@]}"; do
  [ -e "$HOME/.xui/$part" ] && EXISTING+=("$part")
done
if [ "${#EXISTING[@]}" -eq 0 ]; then
  echo "Nothing to backup under $HOME/.xui" >&2
  exit 1
fi
tar -czf "$DST" -C "$HOME/.xui" "${EXISTING[@]}"
echo "$DST"
BASH
    chmod +x "$BIN_DIR/xui_backup.sh"

    cat > "$BIN_DIR/xui_restore.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
ARCH=${1:-}
if [ -z "$ARCH" ]; then echo "Usage: $0 <backup-archive>"; exit 1; fi
[ -f "$ARCH" ] || { echo "Backup archive not found: $ARCH"; exit 1; }
mkdir -p "$HOME/.xui"
tar -tzf "$ARCH" >/dev/null || { echo "Invalid archive: $ARCH"; exit 1; }
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
        out="$PROFDIR/$name.tgz"
        if tar -czf "$out" -C "$HOME/.xui" data; then
            echo "Saved profile: $out"
        else
            echo "Profile save failed"
            exit 1
        fi
        ;;
    restore)
        file=${2:-}
        [ -n "$file" ] || { echo "Usage: $0 restore <file>"; exit 1; }
        [ -f "$file" ] || { echo "Profile archive not found: $file"; exit 1; }
        if tar -xzf "$file" -C "$HOME/.xui"; then
            echo "Restored profile from $file"
        else
            echo "Profile restore failed"
            exit 1
        fi
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
MODE="${1:-status}"
shift || true
JSON_OUT=0
if [ "${1:-}" = "--json" ]; then
  JSON_OUT=1
  shift || true
fi

REPO="${XUI_UPDATE_REPO:-afitler79-alt/XUI-X360-FRONTEND}"
SRC="${XUI_SOURCE_DIR:-$HOME/.xui/src/XUI-X360-FRONTEND}"
INSTALLER_NAME="${XUI_UPDATE_INSTALLER:-xui11.sh.fixed.sh}"
STATE_FILE="$HOME/.xui/data/update_state.json"
mkdir -p "$(dirname "$STATE_FILE")"

require_cmd(){
  command -v "$1" >/dev/null 2>&1
}

now_iso(){
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

read_state_commit(){
  python3 - "$STATE_FILE" <<'PY'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1])
if not p.exists():
    print("")
    raise SystemExit(0)
try:
    d=json.loads(p.read_text(encoding='utf-8'))
except Exception:
    print("")
    raise SystemExit(0)
print(str(d.get('installed_commit','') or '').strip())
PY
}

write_state(){
  local commit="$1"
  local branch="$2"
  local remote_date="$3"
  local src="$4"
  python3 - "$STATE_FILE" "$commit" "$branch" "$remote_date" "$src" <<'PY'
import json,sys,time,pathlib
path=pathlib.Path(sys.argv[1])
data={
  "installed_commit": str(sys.argv[2] or ""),
  "branch": str(sys.argv[3] or ""),
  "remote_date": str(sys.argv[4] or ""),
  "installed_at_epoch": int(time.time()),
  "source_dir": str(sys.argv[5] or ""),
  "version": 2,
}
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding='utf-8')
print("state-updated")
PY
}

remote_meta_line(){
  python3 - "$REPO" <<'PY'
import json,sys,urllib.request,urllib.error
repo=sys.argv[1]
headers={
  "Accept":"application/vnd.github+json",
  "User-Agent":"xui-update-checker",
}
def fetch(url, timeout=10):
  req=urllib.request.Request(url, headers=headers)
  with urllib.request.urlopen(req, timeout=timeout) as r:
    return json.loads(r.read().decode('utf-8', errors='ignore'))
try:
  repo_info=fetch(f"https://api.github.com/repos/{repo}")
  branch=str(repo_info.get("default_branch") or "main").strip() or "main"
  commit=fetch(f"https://api.github.com/repos/{repo}/commits/{branch}")
  sha=str(commit.get("sha") or "").strip()
  date=str((((commit.get("commit") or {}).get("committer") or {}).get("date")) or "")
  html=str(commit.get("html_url") or "")
  if not sha:
    print("ERR\t\t\t\tmissing-remote-sha")
    raise SystemExit(0)
  print(f"OK\t{branch}\t{sha}\t{date}\t{html}")
except Exception as exc:
  msg=str(exc).replace("\t"," ").replace("\n"," ")
  print(f"ERR\t\t\t\t{msg}")
PY
}

emit_json(){
  local checked="$1"
  local required="$2"
  local reason="$3"
  local branch="$4"
  local local_commit="$5"
  local remote_commit="$6"
  local remote_date="$7"
  local remote_url="$8"
  python3 - "$checked" "$required" "$reason" "$REPO" "$branch" "$local_commit" "$remote_commit" "$remote_date" "$remote_url" <<'PY'
import json,sys
checked = str(sys.argv[1]).strip() == "1"
required = str(sys.argv[2]).strip() == "1"
obj = {
  "checked": checked,
  "mandatory": True,
  "update_required": required,
  "reason": str(sys.argv[3]),
  "repo": str(sys.argv[4]),
  "branch": str(sys.argv[5]),
  "local_commit": str(sys.argv[6]),
  "remote_commit": str(sys.argv[7]),
  "remote_date": str(sys.argv[8]),
  "remote_url": str(sys.argv[9]),
}
print(json.dumps(obj, ensure_ascii=False))
PY
}

compute_status(){
  local line status branch remote_commit remote_date remote_url extra
  local checked=0 required=0 reason="unknown"
  local local_commit=""
  local_commit="$(read_state_commit)"

  line="$(remote_meta_line)"
  IFS=$'\t' read -r status branch remote_commit remote_date remote_url extra <<<"$line"
  if [ "$status" != "OK" ]; then
    checked=0
    required=0
    reason="remote-unavailable:${extra:-unknown}"
    branch="${branch:-main}"
    remote_commit=""
    remote_date=""
    remote_url=""
  else
    checked=1
    if [ -z "$local_commit" ]; then
      required=1
      reason="missing-local-version"
    elif [ "$local_commit" != "$remote_commit" ]; then
      required=1
      reason="outdated"
    else
      required=0
      reason="up-to-date"
    fi
  fi

  if [ "$JSON_OUT" = "1" ]; then
    emit_json "$checked" "$required" "$reason" "$branch" "$local_commit" "$remote_commit" "$remote_date" "$remote_url"
    return 0
  fi

  echo "Repo: $REPO"
  echo "Branch: ${branch:-main}"
  echo "Checked: $([ "$checked" = "1" ] && echo yes || echo no)"
  echo "Mandatory: yes"
  echo "Local commit: ${local_commit:-<none>}"
  echo "Remote commit: ${remote_commit:-<unknown>}"
  [ -n "$remote_date" ] && echo "Remote date: $remote_date"
  [ -n "$remote_url" ] && echo "Remote URL: $remote_url"
  echo "Update required: $([ "$required" = "1" ] && echo yes || echo no)"
  echo "Reason: $reason"
  if [ "$required" = "1" ]; then
    return 10
  fi
  return 0
}

apply_update(){
  local line status branch remote_commit remote_date remote_url extra
  if ! require_cmd git; then
    echo "git is required for apply mode"
    exit 1
  fi

  line="$(remote_meta_line)"
  IFS=$'\t' read -r status branch remote_commit remote_date remote_url extra <<<"$line"
  if [ "$status" != "OK" ]; then
    echo "Cannot reach GitHub metadata: ${extra:-unknown}"
    exit 1
  fi

  clone_fresh_repo(){
    local tmp="${SRC}.tmp.$$"
    rm -rf "$tmp"
    git clone "https://github.com/$REPO.git" "$tmp"
    rm -rf "$SRC"
    mv "$tmp" "$SRC"
  }

  mkdir -p "$(dirname "$SRC")"
  if [ ! -d "$SRC/.git" ]; then
    clone_fresh_repo
  fi

  if ! git -C "$SRC" fetch --all --prune; then
    echo "Fetch failed, recloning source..."
    clone_fresh_repo
    git -C "$SRC" fetch --all --prune
  fi
  if ! git -C "$SRC" checkout -B "$branch" "origin/$branch" >/dev/null 2>&1; then
    echo "Checkout failed, recloning source..."
    clone_fresh_repo
    git -C "$SRC" fetch --all --prune
    git -C "$SRC" checkout -B "$branch" "origin/$branch"
  fi
  if ! git -C "$SRC" reset --hard "origin/$branch" >/dev/null 2>&1; then
    echo "Reset failed, recloning source..."
    clone_fresh_repo
    git -C "$SRC" fetch --all --prune
    git -C "$SRC" checkout -B "$branch" "origin/$branch"
    git -C "$SRC" reset --hard "origin/$branch"
  fi
  git -C "$SRC" clean -fd >/dev/null 2>&1 || true

  find_installer(){
    local c f
    local names=(
      "$INSTALLER_NAME"
      "xui11.sh.fixed.sh"
      "xui11.sh.fixed"
      "xui11.sh"
      "install.sh"
      "installer.sh"
      "main-xui.sh"
      "Main-XUI.sh"
    )
    for c in "${names[@]}"; do
      [ -n "$c" ] || continue
      if [ -f "$SRC/$c" ]; then
        echo "$SRC/$c"
        return 0
      fi
    done
    for c in "${names[@]}"; do
      [ -n "$c" ] || continue
      f="$(find "$SRC" -maxdepth 6 -type f -name "$c" 2>/dev/null | head -n 1 || true)"
      if [ -n "$f" ]; then
        echo "$f"
        return 0
      fi
    done
    while IFS= read -r f; do
      if grep -q "write_dashboard_py" "$f" 2>/dev/null && grep -q "write_auto_update" "$f" 2>/dev/null; then
        echo "$f"
        return 0
      fi
    done < <(find "$SRC" -maxdepth 6 -type f -name "*.sh" 2>/dev/null | sort)
    f="$(find "$SRC" -maxdepth 6 -type f \( -iname '*xui*installer*.sh' -o -iname '*xui11*.sh' -o -iname '*main*xui*.sh' \) 2>/dev/null | head -n 1 || true)"
    if [ -n "$f" ]; then
      echo "$f"
      return 0
    fi
    return 1
  }

  local installer=""
  installer="$(find_installer || true)"
  if [ -z "$installer" ]; then
    echo "Installer not found in repo: $SRC"
    exit 1
  fi

  echo "step=installer-start"
  (
    cd "$SRC"
    if command -v timeout >/dev/null 2>&1; then
      AUTO_CONFIRM=1 XUI_SKIP_LAUNCH_PROMPT=1 XUI_NONINTERACTIVE=1 XUI_SYSTEMCTL_TIMEOUT_SEC="${XUI_SYSTEMCTL_TIMEOUT_SEC:-15}" \
        timeout "${XUI_APPLY_INSTALLER_TIMEOUT_SEC:-900}" bash "$installer" --no-auto-install --skip-apt-wait
    else
      AUTO_CONFIRM=1 XUI_SKIP_LAUNCH_PROMPT=1 XUI_NONINTERACTIVE=1 XUI_SYSTEMCTL_TIMEOUT_SEC="${XUI_SYSTEMCTL_TIMEOUT_SEC:-15}" \
        bash "$installer" --no-auto-install --skip-apt-wait
    fi
  )
  echo "step=installer-done"

  if [ -x "$HOME/.xui/bin/xui_install_fnae_deps.sh" ]; then
    # Keep mandatory update responsive: run FNAE deps best-effort in background.
    (
      if command -v timeout >/dev/null 2>&1; then
        XUI_NONINTERACTIVE=1 timeout "${XUI_FNAE_DEPS_TIMEOUT_SEC:-90}" "$HOME/.xui/bin/xui_install_fnae_deps.sh" || true
      else
        XUI_NONINTERACTIVE=1 "$HOME/.xui/bin/xui_install_fnae_deps.sh" || true
      fi
    ) >/dev/null 2>&1 &
    echo "step=fnae-deps-background"
  fi

  local installed_commit=""
  installed_commit="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)"
  if [ -z "$installed_commit" ]; then
    installed_commit="$remote_commit"
  fi
  write_state "$installed_commit" "$branch" "$remote_date" "$SRC" >/dev/null
  echo "step=state-written"
  echo "update-applied"
  echo "installed_commit=$installed_commit"
}

pull_only(){
  if [ ! -d "$SRC/.git" ]; then
    echo "No git repo at $SRC"
    echo "Tip: run '$0 apply' to clone and install automatically."
    exit 1
  fi
  git -C "$SRC" fetch --all --prune
  git -C "$SRC" pull --ff-only
}

release_info(){
  python3 - "$REPO" <<'PY'
import json,sys,urllib.request
repo=sys.argv[1]
headers={"Accept":"application/vnd.github+json","User-Agent":"xui-update-checker"}
req=urllib.request.Request(f"https://api.github.com/repos/{repo}/releases/latest", headers=headers)
try:
  with urllib.request.urlopen(req, timeout=10) as r:
    d=json.loads(r.read().decode("utf-8", errors="ignore"))
  print("Latest release:", d.get("tag_name","unknown"))
except Exception as exc:
  print("Could not query latest release:", exc)
  raise SystemExit(1)
PY
}

mark_current(){
  if [ ! -d "$SRC/.git" ]; then
    echo "No git repo at $SRC"
    exit 1
  fi
  local commit branch
  commit="$(git -C "$SRC" rev-parse HEAD)"
  branch="$(git -C "$SRC" rev-parse --abbrev-ref HEAD)"
  write_state "$commit" "$branch" "" "$SRC" >/dev/null
  echo "marked-installed=$commit"
}

case "$MODE" in
  status|mandatory)
    compute_status
    ;;
  pull)
    pull_only
    ;;
  apply)
    apply_update
    ;;
  release)
    release_info
    ;;
  mark)
    mark_current
    ;;
  *)
    echo "Usage: $0 {status|mandatory|pull|apply|release|mark} [--json]"
    exit 1
    ;;
esac
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

    # Custom Chromium-based web hub + launcher
    cat > "$BIN_DIR/xui_webhub.py" <<'PY'
#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path
from PyQt5 import QtCore, QtGui, QtWidgets
try:
    from PyQt5 import QtWebEngineWidgets
except Exception:
    QtWebEngineWidgets = None
try:
    from PyQt5 import QtGamepad
except Exception:
    QtGamepad = None

DATA_HOME = Path.home() / '.xui' / 'data'
RECENT_FILE = DATA_HOME / 'webhub_recent.json'
FAV_FILE = DATA_HOME / 'webhub_favorites.json'
SOCIAL_MESSAGES_FILE = DATA_HOME / 'social_messages_recent.json'
MAX_RECENT = 24


def safe_read(path, default):
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except Exception:
        return default


def safe_write(path, data):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding='utf-8')


def normalize_url(text):
    raw = str(text or '').strip()
    if not raw:
        return 'https://www.xbox.com'
    if '://' not in raw and not raw.startswith('about:'):
        raw = 'https://' + raw
    return raw


class VirtualKeyboardDialog(QtWidgets.QDialog):
    def __init__(self, initial='', parent=None):
        super().__init__(parent)
        self._nav_default_cols = 10
        self.setWindowTitle('Virtual Keyboard')
        self.setWindowFlags(QtCore.Qt.Dialog | QtCore.Qt.FramelessWindowHint)
        self.setModal(True)
        self.resize(900, 420)
        self.setStyleSheet('''
            QDialog { background:#d2d7dc; border:2px solid #e8edf1; }
            QLineEdit { background:#ffffff; border:1px solid #8a96a3; color:#1e2731; font-size:23px; font-weight:700; padding:8px; }
            QListWidget { background:#eef2f5; border:1px solid #9da8b3; color:#24303b; font-size:17px; font-weight:800; outline:none; }
            QListWidget::item { border:1px solid #c1c9d2; min-width:72px; min-height:44px; margin:3px; }
            QListWidget::item:selected { background:#66b340; color:#fff; border:2px solid #2f6e28; }
            QLabel { color:#2f3944; font-size:14px; font-weight:700; }
        ''')
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(12, 10, 12, 10)
        v.setSpacing(8)
        self.edit = QtWidgets.QLineEdit(str(initial or ''))
        self.edit.setFocusPolicy(QtCore.Qt.ClickFocus)
        self.edit.installEventFilter(self)
        v.addWidget(self.edit)
        self.keys = QtWidgets.QListWidget()
        self.keys.setViewMode(QtWidgets.QListView.IconMode)
        self.keys.setMovement(QtWidgets.QListView.Static)
        self.keys.setResizeMode(QtWidgets.QListView.Adjust)
        self.keys.setWrapping(True)
        self.keys.setSpacing(4)
        self.keys.setGridSize(QtCore.QSize(84, 54))
        self.keys.itemActivated.connect(self._activate_current)
        self.keys.installEventFilter(self)
        for token in list("1234567890QWERTYUIOPASDFGHJKLZXCVBNM") + ['-', '_', '@', '.', '/', ':', 'SPACE', 'BACK', 'CLEAR', 'DONE']:
            self.keys.addItem(QtWidgets.QListWidgetItem(token))
        self.keys.setCurrentRow(0)
        self.keys.setFocus(QtCore.Qt.OtherFocusReason)
        v.addWidget(self.keys, 1)
        v.addWidget(QtWidgets.QLabel('A/ENTER = Select | B/ESC = Back | X = Backspace | Y = Space'))

    def text(self):
        return self.edit.text()

    def _activate_current(self):
        it = self.keys.currentItem()
        if it is None:
            return
        key = str(it.text() or '')
        if key == 'DONE':
            self.accept()
            return
        if key == 'SPACE':
            self.edit.setText(self.edit.text() + ' ')
            self.keys.setFocus(QtCore.Qt.OtherFocusReason)
            return
        if key == 'BACK':
            self.edit.setText(self.edit.text()[:-1])
            self.keys.setFocus(QtCore.Qt.OtherFocusReason)
            return
        if key == 'CLEAR':
            self.edit.setText('')
            self.keys.setFocus(QtCore.Qt.OtherFocusReason)
            return
        self.edit.setText(self.edit.text() + key)
        self.keys.setFocus(QtCore.Qt.OtherFocusReason)

    def _nav_cols(self):
        try:
            grid_w = int(self.keys.gridSize().width())
            view_w = int(self.keys.viewport().width())
            cols = max(1, view_w // max(1, grid_w))
            return cols
        except Exception:
            return self._nav_default_cols

    def _move_selection(self, dr=0, dc=0):
        total = int(self.keys.count())
        if total <= 0:
            return
        cols = max(1, int(self._nav_cols() or self._nav_default_cols))
        idx = int(self.keys.currentRow())
        if idx < 0:
            idx = 0
        row = idx // cols
        col = idx % cols
        row += int(dr)
        col += int(dc)
        max_row = (total - 1) // cols
        row = max(0, min(max_row, row))
        col = max(0, col)
        row_start = row * cols
        row_end = min(total - 1, row_start + cols - 1)
        new_idx = min(row_end, row_start + col)
        self.keys.setCurrentRow(new_idx)
        it = self.keys.currentItem()
        if it is not None:
            self.keys.scrollToItem(it, QtWidgets.QAbstractItemView.PositionAtCenter)

    def eventFilter(self, obj, event):
        if event.type() == QtCore.QEvent.KeyPress:
            if event.key() in (
                QtCore.Qt.Key_Left, QtCore.Qt.Key_Right,
                QtCore.Qt.Key_Up, QtCore.Qt.Key_Down,
                QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter,
                QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back,
                QtCore.Qt.Key_Space, QtCore.Qt.Key_Backspace,
            ):
                self.keyPressEvent(event)
                return True
        return super().eventFilter(obj, event)

    def keyPressEvent(self, e):
        k = e.key()
        if k in (QtCore.Qt.Key_Left,):
            self._move_selection(0, -1)
            return
        if k in (QtCore.Qt.Key_Right,):
            self._move_selection(0, 1)
            return
        if k in (QtCore.Qt.Key_Up,):
            self._move_selection(-1, 0)
            return
        if k in (QtCore.Qt.Key_Down,):
            self._move_selection(1, 0)
            return
        if k in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.reject()
            return
        if k in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter):
            self._activate_current()
            return
        if k == QtCore.Qt.Key_Space:
            self.edit.setText(self.edit.text() + ' ')
            self.keys.setFocus(QtCore.Qt.OtherFocusReason)
            return
        if k == QtCore.Qt.Key_Backspace:
            self.edit.setText(self.edit.text()[:-1])
            self.keys.setFocus(QtCore.Qt.OtherFocusReason)
            return
        super().keyPressEvent(e)


class WebHub(QtWidgets.QMainWindow):
    def __init__(self, url='https://www.xbox.com', kiosk=False):
        super().__init__()
        self.kiosk = bool(kiosk)
        self.pending_url = normalize_url(url)
        self._kbd_opening = False
        self._skip_web_return_once = 0
        self._gp = None
        self._gp_prev = {}
        self._gp_timer = None
        self.setWindowTitle('XUI Web Hub')
        self.resize(1366, 768)
        self._build()
        self._load_hub_lists()
        self.open_url(self.pending_url)
        self._setup_gamepad()

    def _build(self):
        self.setStyleSheet('''
            QMainWindow { background:#0b1017; color:#e6edf5; }
            QFrame#topbar {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #111820, stop:1 #1b2530);
                border-bottom:1px solid rgba(146,164,184,0.35);
            }
            QLineEdit#addr {
                background:#0f1a24;
                border:1px solid rgba(98,214,92,0.55);
                border-radius:3px;
                padding:6px 8px;
                color:#e8f1f8;
                font-size:16px;
            }
            QPushButton#navbtn {
                background:#182230;
                border:1px solid rgba(125,148,172,0.42);
                color:#f2f7fa;
                border-radius:16px;
                min-width:34px;
                min-height:34px;
                font-size:16px;
                font-weight:700;
            }
            QPushButton#navbtn:hover, QPushButton#navbtn:focus {
                background:#2f8540;
                border:1px solid rgba(184,232,178,0.72);
            }
            QProgressBar#loadbar {
                background:#2a3039;
                border:1px solid rgba(180,190,203,0.22);
                border-radius:2px;
                max-height:8px;
            }
            QProgressBar#loadbar::chunk { background:#50c443; }
            QWidget#hub {
                background:qlineargradient(x1:0,y1:0,x2:0,y2:1, stop:0 #101722, stop:1 #0c1119);
            }
            QLabel#hubtitle { color:#edf3f9; font-size:32px; font-weight:800; }
            QLabel#sec { color:#e6edf4; font-size:23px; font-weight:760; }
            QListWidget#cards {
                background:#18202b;
                border:1px solid rgba(147,162,181,0.24);
                color:#e9f1f7;
                font-size:18px;
            }
            QListWidget#cards::item { padding:9px 10px; border:1px solid transparent; }
            QListWidget#cards::item:selected {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #46ba3e, stop:1 #2e8d34);
                border:1px solid rgba(216,243,212,0.50);
                color:#f6fff6;
            }
            QLabel#hint { color:rgba(226,236,247,0.85); font-size:15px; }
        ''')
        root = QtWidgets.QWidget()
        self.setCentralWidget(root)
        v = QtWidgets.QVBoxLayout(root)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(0)

        top = QtWidgets.QFrame()
        top.setObjectName('topbar')
        t = QtWidgets.QVBoxLayout(top)
        t.setContentsMargins(10, 8, 10, 8)
        t.setSpacing(5)
        row = QtWidgets.QHBoxLayout()
        row.setSpacing(7)
        self.btn_back = QtWidgets.QPushButton('<')
        self.btn_fwd = QtWidgets.QPushButton('>')
        self.btn_refresh = QtWidgets.QPushButton('R')
        self.btn_hub = QtWidgets.QPushButton('H')
        self.btn_close = QtWidgets.QPushButton('X')
        for b in (self.btn_back, self.btn_fwd, self.btn_refresh, self.btn_hub, self.btn_close):
            b.setObjectName('navbtn')
            row.addWidget(b, 0)
        self.addr = QtWidgets.QLineEdit()
        self.addr.setObjectName('addr')
        self.addr.setPlaceholderText('https://...')
        self.addr.installEventFilter(self)
        row.addWidget(self.addr, 1)
        t.addLayout(row)
        self.bar = QtWidgets.QProgressBar()
        self.bar.setObjectName('loadbar')
        self.bar.setRange(0, 100)
        self.bar.setValue(0)
        self.bar.setTextVisible(False)
        t.addWidget(self.bar)
        v.addWidget(top, 0)

        self.stack = QtWidgets.QStackedWidget()
        if QtWebEngineWidgets is None:
            fallback = QtWidgets.QTextEdit()
            fallback.setReadOnly(True)
            fallback.setPlainText('QtWebEngine is not installed. Install python3-pyqt5.qtwebengine.')
            self.web = None
            self.stack.addWidget(fallback)
        else:
            self.web = QtWebEngineWidgets.QWebEngineView()
            self.web.installEventFilter(self)
            self.stack.addWidget(self.web)
        self.hub = self._build_hub_widget()
        self.stack.addWidget(self.hub)
        v.addWidget(self.stack, 1)

        self.btn_back.clicked.connect(self._go_back)
        self.btn_fwd.clicked.connect(self._go_forward)
        self.btn_refresh.clicked.connect(self._reload)
        self.btn_hub.clicked.connect(self._show_hub)
        self.btn_close.clicked.connect(self.close)
        self.addr.returnPressed.connect(self._open_from_bar)

        if self.web is not None:
            self.web.loadProgress.connect(self.bar.setValue)
            self.web.titleChanged.connect(self.setWindowTitle)
            self.web.urlChanged.connect(self._on_url_changed)
            self.web.loadFinished.connect(self._on_loaded)

        QtWidgets.QShortcut(QtGui.QKeySequence(QtCore.Qt.Key_Escape), self, activated=self.close)
        QtWidgets.QShortcut(QtGui.QKeySequence(QtCore.Qt.Key_Back), self, activated=self.close)
        QtWidgets.QShortcut(QtGui.QKeySequence('Alt+Left'), self, activated=self._go_back)
        QtWidgets.QShortcut(QtGui.QKeySequence('Alt+Right'), self, activated=self._go_forward)
        QtWidgets.QShortcut(QtGui.QKeySequence('Ctrl+L'), self, activated=self._focus_addr_with_keyboard)
        QtWidgets.QShortcut(QtGui.QKeySequence(QtCore.Qt.Key_F1), self, activated=self._show_guide)
        QtWidgets.QShortcut(QtGui.QKeySequence(QtCore.Qt.Key_Home), self, activated=self._show_guide)
        QtWidgets.QShortcut(QtGui.QKeySequence(QtCore.Qt.Key_F2), self, activated=self._open_virtual_keyboard_contextual)
        QtWidgets.QShortcut(QtGui.QKeySequence('Ctrl+K'), self, activated=self._open_virtual_keyboard_contextual)

    def _recent_messages_text(self):
        arr = safe_read(SOCIAL_MESSAGES_FILE, [])
        if not isinstance(arr, list) or not arr:
            return 'No recent messages.'
        out = []
        for i, item in enumerate(arr[:16], 1):
            if isinstance(item, dict):
                out.append(f"{i:02d}. {item.get('from', 'Unknown')}: {item.get('text', '')}")
            else:
                out.append(f'{i:02d}. {item}')
        return '\n'.join(out)

    def _show_guide(self):
        opts = [
            'Recent Messages',
            'Recent Web',
            'Virtual Keyboard',
            'Toggle Hub',
            'Close Current App',
        ]
        d = QtWidgets.QDialog(self)
        d.setWindowTitle('Xbox Guide')
        d.setModal(True)
        d.resize(700, 420)
        d.setStyleSheet('QDialog{background:#d8dde3;} QListWidget{font-size:24px;font-weight:700;}')
        lay = QtWidgets.QVBoxLayout(d)
        lw = QtWidgets.QListWidget()
        lw.addItems(opts)
        lw.setCurrentRow(0)
        lay.addWidget(lw, 1)
        hint = QtWidgets.QLabel('A/ENTER select | B/ESC back')
        lay.addWidget(hint)
        lw.itemActivated.connect(lambda *_: d.accept())
        if d.exec_() != QtWidgets.QDialog.Accepted:
            return
        cur = lw.currentItem()
        choice = cur.text() if cur else ''
        if choice == 'Close Current App':
            self.close()
        elif choice == 'Toggle Hub':
            self._show_hub()
        elif choice == 'Virtual Keyboard':
            self._open_virtual_keyboard_contextual()
        elif choice == 'Recent Messages':
            QtWidgets.QMessageBox.information(self, 'Recent Messages', self._recent_messages_text())
        elif choice == 'Recent Web':
            rec = safe_read(RECENT_FILE, [])
            if not isinstance(rec, list) or not rec:
                QtWidgets.QMessageBox.information(self, 'Recent Web', 'No recent web activity.')
            else:
                QtWidgets.QMessageBox.information(self, 'Recent Web', '\n'.join(str(x) for x in rec[:20]))

    def _setup_gamepad(self):
        if QtGamepad is None:
            return
        try:
            mgr = QtGamepad.QGamepadManager.instance()
            ids = list(mgr.connectedGamepads())
            if not ids:
                return
            self._gp = QtGamepad.QGamepad(ids[0], self)
            self._gp_timer = QtCore.QTimer(self)
            self._gp_timer.timeout.connect(self._poll_gamepad)
            self._gp_timer.start(75)
        except Exception:
            self._gp = None

    def _gpv(self, name, default=0.0):
        gp = self._gp
        if gp is None:
            return default
        v = getattr(gp, name, None)
        try:
            return v() if callable(v) else v
        except Exception:
            return default

    def _send_key_focus(self, key):
        w = QtWidgets.QApplication.focusWidget() or self
        press = QtGui.QKeyEvent(QtCore.QEvent.KeyPress, key, QtCore.Qt.NoModifier)
        rel = QtGui.QKeyEvent(QtCore.QEvent.KeyRelease, key, QtCore.Qt.NoModifier)
        QtWidgets.QApplication.postEvent(w, press)
        QtWidgets.QApplication.postEvent(w, rel)

    def _poll_gamepad(self):
        gp = self._gp
        if gp is None:
            return
        cur = {
            'left': bool(self._gpv('buttonLeft', False)) or float(self._gpv('axisLeftX', 0.0)) < -0.6,
            'right': bool(self._gpv('buttonRight', False)) or float(self._gpv('axisLeftX', 0.0)) > 0.6,
            'up': bool(self._gpv('buttonUp', False)) or float(self._gpv('axisLeftY', 0.0)) < -0.6,
            'down': bool(self._gpv('buttonDown', False)) or float(self._gpv('axisLeftY', 0.0)) > 0.6,
            'a': bool(self._gpv('buttonA', False)),
            'b': bool(self._gpv('buttonB', False)),
            'x': bool(self._gpv('buttonX', False)),
            'guide': bool(self._gpv('buttonGuide', False)),
            'lb': bool(self._gpv('buttonL1', False)),
            'rb': bool(self._gpv('buttonR1', False)),
        }

        def pressed(name):
            return cur.get(name, False) and not self._gp_prev.get(name, False)

        if pressed('guide'):
            self._show_guide()
        elif pressed('x'):
            self._open_virtual_keyboard_contextual()
        elif pressed('b'):
            if self.stack.currentWidget() is self.hub:
                self.close()
            else:
                self._go_back()
        elif pressed('lb'):
            self._go_back()
        elif pressed('rb'):
            self._go_forward()
        elif pressed('a'):
            if self.stack.currentWidget() is self.hub:
                self._send_key_focus(QtCore.Qt.Key_Return)
            else:
                self._open_keyboard_if_web_editable()
        elif pressed('left'):
            self._send_key_focus(QtCore.Qt.Key_Left)
        elif pressed('right'):
            self._send_key_focus(QtCore.Qt.Key_Right)
        elif pressed('up'):
            self._send_key_focus(QtCore.Qt.Key_Up)
        elif pressed('down'):
            self._send_key_focus(QtCore.Qt.Key_Down)
        self._gp_prev = cur

    def _focus_addr_with_keyboard(self):
        self.addr.setFocus()
        self._open_virtual_keyboard_for_addr()

    def _open_virtual_keyboard_for_addr(self):
        if self._kbd_opening:
            return
        self._kbd_opening = True
        try:
            d = VirtualKeyboardDialog(self.addr.text(), self)
            if d.exec_() == QtWidgets.QDialog.Accepted:
                txt = d.text()
                self.addr.setText(txt)
                if txt.strip():
                    self._open_from_bar()
        finally:
            self._kbd_opening = False

    def _inject_text_into_page(self, text):
        if self.web is None:
            return
        payload = json.dumps(str(text or ''))
        js = f"""
(() => {{
  const el = document.activeElement;
  if (!el) return false;
  const tag = (el.tagName || '').toLowerCase();
  const tp = (el.type || '').toLowerCase();
  const editable = el.isContentEditable || tag === 'textarea' ||
    (tag === 'input' && !['button','submit','checkbox','radio','range','color','file','image','reset'].includes(tp));
  if (!editable) return false;
  const txt = {payload};
  if (el.isContentEditable) {{
    try {{ document.execCommand('insertText', false, txt); }} catch (_e) {{ el.textContent = (el.textContent || '') + txt; }}
  }} else {{
    el.value = (el.value || '') + txt;
  }}
  el.dispatchEvent(new Event('input', {{ bubbles: true }}));
  el.dispatchEvent(new Event('change', {{ bubbles: true }}));
  return true;
}})();
"""
        self.web.page().runJavaScript(js)

    def _forward_enter_to_web(self):
        if self.web is None:
            return
        self._skip_web_return_once = 1
        press = QtGui.QKeyEvent(QtCore.QEvent.KeyPress, QtCore.Qt.Key_Return, QtCore.Qt.NoModifier)
        rel = QtGui.QKeyEvent(QtCore.QEvent.KeyRelease, QtCore.Qt.Key_Return, QtCore.Qt.NoModifier)
        QtWidgets.QApplication.postEvent(self.web, press)
        QtWidgets.QApplication.postEvent(self.web, rel)

    def _open_keyboard_if_web_editable(self):
        if self.web is None:
            return
        probe = """
(() => {
  const el = document.activeElement;
  if (!el) return false;
  const tag = (el.tagName || '').toLowerCase();
  const tp = (el.type || '').toLowerCase();
  return !!(el.isContentEditable || tag === 'textarea' ||
    (tag === 'input' && !['button','submit','checkbox','radio','range','color','file','image','reset'].includes(tp)));
})();
"""
        def cb(editable):
            if bool(editable):
                self._open_virtual_keyboard_for_web()
            else:
                self._forward_enter_to_web()
        self.web.page().runJavaScript(probe, cb)

    def _open_virtual_keyboard_for_web(self):
        if self.web is None:
            return
        d = VirtualKeyboardDialog('', self)
        if d.exec_() == QtWidgets.QDialog.Accepted:
            txt = d.text()
            if txt:
                self._inject_text_into_page(txt)

    def _open_virtual_keyboard_contextual(self):
        if self.stack.currentWidget() is self.hub:
            self._open_virtual_keyboard_for_addr()
        else:
            self._open_virtual_keyboard_for_web()

    def eventFilter(self, obj, event):
        if obj is self.addr and event.type() == QtCore.QEvent.FocusIn:
            QtCore.QTimer.singleShot(0, self._open_virtual_keyboard_for_addr)
        if obj is self.web and event.type() == QtCore.QEvent.KeyPress:
            if event.key() in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter):
                if self._skip_web_return_once > 0:
                    self._skip_web_return_once -= 1
                    return False
                self._open_keyboard_if_web_editable()
                return True
        return super().eventFilter(obj, event)

    def _build_hub_widget(self):
        hub = QtWidgets.QWidget()
        hub.setObjectName('hub')
        v = QtWidgets.QVBoxLayout(hub)
        v.setContentsMargins(16, 14, 16, 12)
        v.setSpacing(8)
        ttl = QtWidgets.QLabel('Web Hub')
        ttl.setObjectName('hubtitle')
        v.addWidget(ttl)
        grid = QtWidgets.QGridLayout()
        grid.setHorizontalSpacing(10)
        grid.setVerticalSpacing(8)
        self.fav_list = QtWidgets.QListWidget()
        self.recent_list = QtWidgets.QListWidget()
        self.featured_list = QtWidgets.QListWidget()
        for lw in (self.fav_list, self.recent_list, self.featured_list):
            lw.setObjectName('cards')
            lw.itemActivated.connect(self._open_card)
            lw.itemDoubleClicked.connect(self._open_card)
            lw.setMinimumHeight(210)
        grid.addWidget(self._section('Favorites', self.fav_list), 0, 0)
        grid.addWidget(self._section('Recent', self.recent_list), 0, 1)
        grid.addWidget(self._section('Featured', self.featured_list), 0, 2)
        v.addLayout(grid, 1)
        hint = QtWidgets.QLabel('ENTER = open | F1 = toggle hub | ESC = close browser')
        hint.setObjectName('hint')
        v.addWidget(hint)
        return hub

    def _section(self, title, body):
        w = QtWidgets.QWidget()
        l = QtWidgets.QVBoxLayout(w)
        l.setContentsMargins(0, 0, 0, 0)
        l.setSpacing(4)
        t = QtWidgets.QLabel(title)
        t.setObjectName('sec')
        l.addWidget(t)
        l.addWidget(body, 1)
        return w

    def _load_hub_lists(self):
        defaults = [
            'https://www.xbox.com',
            'https://www.youtube.com',
            'https://news.ycombinator.com',
            'https://www.github.com',
            'https://www.reddit.com/r/linux_gaming',
        ]
        favs = safe_read(FAV_FILE, defaults)
        if not isinstance(favs, list) or not favs:
            favs = defaults
        safe_write(FAV_FILE, favs[:20])
        self.fav_list.clear()
        for u in favs[:20]:
            self.fav_list.addItem(str(u))
        rec = safe_read(RECENT_FILE, [])
        self.recent_list.clear()
        for u in rec[:20]:
            self.recent_list.addItem(str(u))
        self.featured_list.clear()
        featured = [
            'https://www.xbox.com/en-US/games',
            'https://store.steampowered.com',
            'https://www.gog.com',
            'https://www.retroarch.com',
            'https://www.duckduckgo.com',
        ]
        for u in featured:
            self.featured_list.addItem(u)

    def _remember_recent(self, url):
        u = str(url or '').strip()
        if not u or u.startswith('about:'):
            return
        rec = safe_read(RECENT_FILE, [])
        if not isinstance(rec, list):
            rec = []
        rec = [x for x in rec if str(x) != u]
        rec.insert(0, u)
        safe_write(RECENT_FILE, rec[:MAX_RECENT])
        self._load_hub_lists()

    def _open_card(self, item):
        if item is None:
            return
        self.open_url(item.text())

    def _show_hub(self):
        if self.stack.currentWidget() is self.hub:
            if self.web is not None:
                self.stack.setCurrentWidget(self.web)
            return
        self._load_hub_lists()
        self.stack.setCurrentWidget(self.hub)

    def _open_from_bar(self):
        self.open_url(self.addr.text())

    def open_url(self, raw):
        url = normalize_url(raw)
        self.addr.setText(url)
        if self.web is None:
            return
        self.stack.setCurrentWidget(self.web)
        self.web.load(QtCore.QUrl(url))

    def _on_url_changed(self, qurl):
        s = qurl.toString()
        self.addr.setText(s)

    def _on_loaded(self, ok):
        if ok and self.web is not None:
            self._remember_recent(self.web.url().toString())

    def _go_back(self):
        if self.web is not None:
            self.web.back()

    def _go_forward(self):
        if self.web is not None:
            self.web.forward()

    def _reload(self):
        if self.web is not None:
            self.web.reload()

    def showEvent(self, e):
        super().showEvent(e)
        if self.kiosk:
            try:
                self.showFullScreen()
            except Exception:
                pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--mode', choices=['hub', 'kiosk', 'normal'], default='hub')
    parser.add_argument('url', nargs='?', default='https://www.xbox.com')
    args = parser.parse_args()
    app = QtWidgets.QApplication(sys.argv)
    fullscreen_mode = args.mode in ('hub', 'kiosk')
    w = WebHub(url=args.url, kiosk=fullscreen_mode)
    if fullscreen_mode:
        try:
            w.showFullScreen()
        except Exception:
            try:
                w.showMaximized()
            except Exception:
                w.show()
    else:
        w.show()
    sys.exit(app.exec_())


if __name__ == '__main__':
    main()
PY
    chmod +x "$BIN_DIR/xui_webhub.py"

    cat > "$BIN_DIR/xui_browser.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
MODE=hub
URL="https://www.xbox.com"
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --kiosk) MODE=kiosk; shift ;;
    --hub) MODE=hub; shift ;;
    --normal) MODE=normal; shift ;;
    *) URL="${1:-$URL}"; shift ;;
  esac
done

PYRUN="$HOME/.xui/bin/xui_python.sh"
WEBHUB="$HOME/.xui/bin/xui_webhub.py"
if [ -x "$PYRUN" ] && [ -f "$WEBHUB" ]; then
  exec "$PYRUN" "$WEBHUB" --mode "$MODE" "$URL"
fi
if command -v python3 >/dev/null 2>&1 && [ -f "$WEBHUB" ]; then
  exec python3 "$WEBHUB" --mode "$MODE" "$URL"
fi

if command -v chromium-browser >/dev/null 2>&1; then
  if [ "$MODE" = "normal" ]; then
    exec chromium-browser "$URL"
  elif [ "$MODE" = "kiosk" ]; then
    exec chromium-browser --kiosk "$URL"
  else
    exec chromium-browser --start-fullscreen "$URL"
  fi
fi
if command -v chromium >/dev/null 2>&1; then
  if [ "$MODE" = "normal" ]; then
    exec chromium "$URL"
  elif [ "$MODE" = "kiosk" ]; then
    exec chromium --kiosk "$URL"
  else
    exec chromium --start-fullscreen "$URL"
  fi
fi
if command -v firefox >/dev/null 2>&1; then
  if [ "$MODE" = "normal" ]; then
    exec firefox "$URL"
  else
    exec firefox --kiosk "$URL"
  fi
fi
if command -v x-www-browser >/dev/null 2>&1; then
  exec x-www-browser "$URL"
fi
echo "No browser runtime found."
exit 1
BASH
    chmod +x "$BIN_DIR/xui_browser.sh"

  cat > "$BIN_DIR/xui_close_active_app.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
PID_FILE="$HOME/.xui/data/active_game.pid"
PAUSED_FILE="$HOME/.xui/data/active_paused.pid"
if [ -f "$PID_FILE" ]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" >/dev/null 2>&1 || true
    sleep 0.3
    kill -9 "$pid" >/dev/null 2>&1 || true
    rm -f "$PID_FILE"
    rm -f "$PAUSED_FILE"
    echo "Closed tracked game process $pid"
    exit 0
  fi
fi
if ! command -v xdotool >/dev/null 2>&1; then
  echo "xdotool not installed."
  exit 1
fi
wid="$(xdotool getactivewindow 2>/dev/null || true)"
if [ -z "$wid" ]; then
  echo "No active window."
  exit 1
fi
name="$(xdotool getwindowname "$wid" 2>/dev/null || true)"
if echo "$name" | grep -Eiq 'xui|dashboard'; then
  echo "No tracked external game found; refusing to close dashboard window."
  exit 1
fi
pid="$(xdotool getwindowpid "$wid" 2>/dev/null || true)"
xdotool windowactivate "$wid" key --clearmodifiers Alt+F4 >/dev/null 2>&1 || true
sleep 0.3
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  kill "$pid" >/dev/null 2>&1 || true
  sleep 0.2
  kill -9 "$pid" >/dev/null 2>&1 || true
fi
rm -f "$PAUSED_FILE"
echo "Close requested for window $wid"
BASH
    chmod +x "$BIN_DIR/xui_close_active_app.sh"

    cat > "$BIN_DIR/xui_resume_active_app.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
PAUSED_FILE="$HOME/.xui/data/active_paused.pid"
if [ ! -f "$PAUSED_FILE" ]; then
  exit 0
fi
pid="$(cat "$PAUSED_FILE" 2>/dev/null || true)"
if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
  kill -CONT "$pid" >/dev/null 2>&1 || true
fi
rm -f "$PAUSED_FILE"
BASH
    chmod +x "$BIN_DIR/xui_resume_active_app.sh"

    cat > "$BIN_DIR/xui_global_guide.py" <<'PY'
#!/usr/bin/env python3
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from PyQt5 import QtCore, QtGui, QtWidgets

DATA = Path.home() / '.xui' / 'data'
PAUSED_FILE = DATA / 'active_paused.pid'
ACTIVE_FILE = DATA / 'active_game.pid'
SOCIAL_FILE = DATA / 'social_messages_recent.json'
RECENT_FILE = DATA / 'recent.json'
PROFILE_FILE = DATA / 'profile.json'
REDEEM_FILE = DATA / 'redeemed_codes.json'
LOCK_FILE = DATA / 'guide_global.lock'
CLOSE_SCRIPT = str(Path.home() / '.xui' / 'bin' / 'xui_close_active_app.sh')
XUI_BIN = Path.home() / '.xui' / 'bin'
SOCIAL_CHAT_APP = XUI_BIN / 'xui_social_chat.py'
PYRUN = XUI_BIN / 'xui_python.sh'


def _json_read(path, default):
    try:
        import json
        return json.loads(Path(path).read_text(encoding='utf-8', errors='ignore'))
    except Exception:
        return default


def _json_write(path, value):
    try:
        import json
        Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')
        return True
    except Exception:
        return False


def _profile_gamertag():
    prof = _json_read(PROFILE_FILE, {})
    if isinstance(prof, dict):
        gt = str(prof.get('gamertag', '')).strip()
        if gt:
            return gt
    return 'Player1'


def _cmdline_of(pid):
    try:
        return Path(f'/proc/{int(pid)}/cmdline').read_text(encoding='utf-8', errors='ignore').replace('\x00', ' ').lower()
    except Exception:
        return ''


def _is_dashboard_pid(pid):
    cl = _cmdline_of(pid)
    return any(t in cl for t in ('pyqt_dashboard_improved.py', 'xui-dashboard.service', 'xui_startup_and_dashboard', 'xui dashboard'))


def _active_window_pid():
    try:
        wid = subprocess.check_output(['xdotool', 'getactivewindow'], text=True, stderr=subprocess.DEVNULL).strip()
        if not wid:
            return None
        pid = subprocess.check_output(['xdotool', 'getwindowpid', wid], text=True, stderr=subprocess.DEVNULL).strip()
        return int(pid) if pid else None
    except Exception:
        return None


def _pick_target_pid():
    try:
        if ACTIVE_FILE.exists():
            pid = int((ACTIVE_FILE.read_text(encoding='utf-8', errors='ignore') or '0').strip() or '0')
            if pid > 1 and not _is_dashboard_pid(pid):
                return pid
    except Exception:
        pass
    pid = _active_window_pid()
    if pid and pid > 1 and not _is_dashboard_pid(pid):
        return pid
    return None


def _pause_pid(pid):
    try:
        os.kill(int(pid), signal.SIGSTOP)
        DATA.mkdir(parents=True, exist_ok=True)
        PAUSED_FILE.write_text(str(int(pid)), encoding='utf-8')
        return True
    except Exception:
        return False


def _resume_paused():
    if not PAUSED_FILE.exists():
        return
    try:
        pid = int((PAUSED_FILE.read_text(encoding='utf-8', errors='ignore') or '0').strip() or '0')
    except Exception:
        pid = 0
    try:
        if pid > 1:
            os.kill(pid, signal.SIGCONT)
    except Exception:
        pass
    try:
        PAUSED_FILE.unlink()
    except Exception:
        pass


def _activate_dashboard():
    cmd = (
        '/bin/sh -lc '
        '"xdotool search --name \'XUI - Xbox 360 Style\' windowactivate 2>/dev/null '
        '|| xdotool search --name \'XUI\' windowactivate 2>/dev/null '
        '|| xdotool search --name \'dashboard\' windowactivate 2>/dev/null"'
    )
    rc = subprocess.call(cmd, shell=True)
    return rc == 0


def _recent_text():
    arr = _json_read(RECENT_FILE, [])
    if not isinstance(arr, list) or not arr:
        return 'No hay actividad reciente todavia.'
    lines = []
    for i, item in enumerate(arr[:12], 1):
        lines.append(f'{i:02d}. {item}')
    return '\n'.join(lines)


def _messages_text():
    arr = _json_read(SOCIAL_FILE, [])
    if not isinstance(arr, list) or not arr:
        return 'No hay mensajes recientes todavia.'
    lines = []
    for i, item in enumerate(arr[:18], 1):
        if isinstance(item, dict):
            who = str(item.get('from', 'Unknown'))
            txt = str(item.get('text', ''))
            lines.append(f'{i:02d}. {who}: {txt}')
        else:
            lines.append(f'{i:02d}. {item}')
    return '\n'.join(lines)


def _downloads_text():
    cmd = (
        "/bin/sh -c \"ps -eo comm,args 2>/dev/null | "
        "egrep -i 'steam|flatpak|apt|dnf|pacman|aria2c|transmission|qbittorrent|wget|curl' "
        "| grep -v egrep | head -n 12\""
    )
    out = subprocess.getoutput(cmd).strip()
    if out:
        return f'Procesos de descarga detectados:\n{out}'
    return 'No se detectan descargas activas.'


def _redeem_code(parent):
    code, ok = QtWidgets.QInputDialog.getText(parent, 'Canjear codigo', 'Introduce tu codigo:')
    if not ok:
        return None
    code = ''.join(ch for ch in str(code).upper() if ch.isalnum() or ch == '-')
    if not code:
        return 'Codigo no valido.'
    redeemed = _json_read(REDEEM_FILE, [])
    if not isinstance(redeemed, list):
        redeemed = []
    if code in redeemed:
        return f'El codigo {code} ya fue usado en este perfil.'
    redeemed.append(code)
    if not _json_write(REDEEM_FILE, redeemed):
        return 'No se pudo guardar el codigo.'
    return f'Codigo {code} guardado correctamente.'


def _close_session():
    prof = _json_read(PROFILE_FILE, {})
    if not isinstance(prof, dict):
        prof = {}
    prof['signed_in'] = False
    _json_write(PROFILE_FILE, prof)


class Guide(QtWidgets.QDialog):
    def __init__(self, gamertag='Player1', paused_pid=None):
        super().__init__()
        self.paused_pid = paused_pid
        self.gamertag = str(gamertag or 'Player1')
        self.action = ''
        self._open_anim = None
        self.setWindowTitle('Guia Xbox')
        self.setWindowFlags(
            QtCore.Qt.Dialog
            | QtCore.Qt.FramelessWindowHint
            | QtCore.Qt.WindowStaysOnTopHint
        )
        self.setAttribute(QtCore.Qt.WA_TranslucentBackground, True)
        self.setModal(True)
        self.resize(860, 500)
        self.setStyleSheet('''
            QFrame#xguide_panel {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #3a3f46, stop:1 #1e242b);
                border:2px solid rgba(214,223,235,0.52);
                border-radius:7px;
            }
            QLabel#xguide_title {
                color:#eef4f8;
                font-size:28px;
                font-weight:800;
            }
            QLabel#xguide_meta {
                color:rgba(235,242,248,0.78);
                font-size:17px;
                font-weight:600;
            }
            QListWidget#xguide_list {
                background:rgba(236,239,242,0.92);
                color:#20252b;
                border:1px solid rgba(0,0,0,0.26);
                font-size:32px;
                outline:none;
            }
            QListWidget#xguide_list::item {
                padding:6px 10px;
                border:1px solid transparent;
            }
            QListWidget#xguide_list::item:selected {
                color:#f3fff2;
                background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #4ea93f, stop:1 #2f8832);
                border:1px solid rgba(255,255,255,0.25);
            }
            QFrame#xguide_blades {
                background:rgba(65,74,84,0.95);
                border:1px solid rgba(194,206,222,0.25);
            }
            QPushButton#xguide_blade_btn {
                text-align:left;
                padding:8px 10px;
                color:#e9f1f8;
                font-size:20px;
                font-weight:700;
                background:rgba(34,43,54,0.92);
                border:1px solid rgba(186,205,224,0.24);
            }
            QPushButton#xguide_blade_btn:focus,
            QPushButton#xguide_blade_btn:hover {
                background:rgba(58,80,106,0.95);
                border:1px solid rgba(218,233,246,0.52);
            }
            QLabel#xguide_hint {
                color:rgba(238,245,250,0.84);
                font-size:15px;
                font-weight:600;
            }
        ''')
        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        panel = QtWidgets.QFrame()
        panel.setObjectName('xguide_panel')
        outer.addWidget(panel)

        root = QtWidgets.QVBoxLayout(panel)
        root.setContentsMargins(12, 10, 12, 10)
        root.setSpacing(8)

        top = QtWidgets.QHBoxLayout()
        title = QtWidgets.QLabel('Guia Xbox')
        title.setObjectName('xguide_title')
        self.meta = QtWidgets.QLabel('')
        self.meta.setObjectName('xguide_meta')
        top.addWidget(title)
        top.addStretch(1)
        top.addWidget(self.meta)
        root.addLayout(top)

        body = QtWidgets.QHBoxLayout()
        body.setSpacing(10)
        self.listw = QtWidgets.QListWidget()
        self.listw.setObjectName('xguide_list')
        self.listw.addItems([
            'Logros',
            'Premios',
            'Reciente',
            'Mensajes recientes',
            'Social global',
            'Mis juegos',
            'Descargas activas',
            'Canjear codigo',
        ])
        self.listw.setCurrentRow(0)
        self.listw.itemActivated.connect(self._accept_current)
        self.listw.itemDoubleClicked.connect(self._accept_current)
        body.addWidget(self.listw, 4)

        blades = QtWidgets.QFrame()
        blades.setObjectName('xguide_blades')
        blades_l = QtWidgets.QVBoxLayout(blades)
        blades_l.setContentsMargins(8, 8, 8, 8)
        blades_l.setSpacing(6)
        for opt in ('Configuracion', 'Inicio de Xbox', 'Cerrar app actual', 'Cerrar sesion'):
            b = QtWidgets.QPushButton(opt)
            b.setObjectName('xguide_blade_btn')
            b.clicked.connect(lambda _=False, opt=opt: self._accept_action(opt))
            blades_l.addWidget(b)
        blades_l.addStretch(1)
        body.addWidget(blades, 2)
        root.addLayout(body, 1)

        hint = QtWidgets.QLabel('A/ENTER = Select | B/ESC = Back | Xbox Guide = F1 o HOME')
        hint.setObjectName('xguide_hint')
        root.addWidget(hint)

        self._clock = QtCore.QTimer(self)
        self._clock.timeout.connect(self._refresh_meta)
        self._clock.start(1000)
        self._refresh_meta()

    def _refresh_meta(self):
        now = QtCore.QDateTime.currentDateTime().toString('HH:mm')
        pid_meta = f' PID:{self.paused_pid}' if self.paused_pid else ''
        self.meta.setText(f'{self.gamertag}    {now}{pid_meta}')

    def _accept_current(self, *_):
        it = self.listw.currentItem()
        if it is None:
            return
        self.action = it.text()
        self.accept()

    def _accept_action(self, action):
        self.action = str(action or '')
        self.accept()

    def showEvent(self, e):
        super().showEvent(e)
        scr = QtWidgets.QApplication.screenAt(QtGui.QCursor.pos()) if hasattr(QtWidgets.QApplication, 'screenAt') else None
        if scr is None:
            scr = QtWidgets.QApplication.primaryScreen()
        if scr is not None:
            g = scr.availableGeometry()
            w = min(max(760, int(g.width() * 0.56)), max(760, g.width() - 120))
            h = min(max(420, int(g.height() * 0.56)), max(420, g.height() - 120))
            self.resize(w, h)
            x = g.x() + max(20, int(g.width() * 0.18))
            y = g.y() + max(20, int(g.height() * 0.12))
            self.move(max(g.x(), x), max(g.y(), y))
        self._refresh_meta()
        self._animate_open()

    def _animate_open(self):
        effect = QtWidgets.QGraphicsOpacityEffect(self)
        self.setGraphicsEffect(effect)
        effect.setOpacity(0.0)
        end_rect = self.geometry()
        start_rect = QtCore.QRect(
            end_rect.x() - max(24, end_rect.width() // 18),
            end_rect.y(),
            end_rect.width(),
            end_rect.height(),
        )
        self.setGeometry(start_rect)
        self._open_anim = QtCore.QParallelAnimationGroup(self)
        fade = QtCore.QPropertyAnimation(effect, b'opacity', self)
        fade.setDuration(190)
        fade.setStartValue(0.0)
        fade.setEndValue(1.0)
        fade.setEasingCurve(QtCore.QEasingCurve.OutCubic)
        slide = QtCore.QPropertyAnimation(self, b'geometry', self)
        slide.setDuration(230)
        slide.setStartValue(start_rect)
        slide.setEndValue(end_rect)
        slide.setEasingCurve(QtCore.QEasingCurve.OutCubic)
        self._open_anim.addAnimation(fade)
        self._open_anim.addAnimation(slide)
        self._open_anim.finished.connect(lambda: self.setGraphicsEffect(None))
        self._open_anim.start(QtCore.QAbstractAnimation.DeleteWhenStopped)

    def keyPressEvent(self, e):
        if e.key() in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.action = ''
            self.reject()
            return
        if e.key() in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter):
            self._accept_current()
            return
        super().keyPressEvent(e)


def _msg(parent, title, text):
    QtWidgets.QMessageBox.information(parent, str(title), str(text))


def _launch_social_global(parent):
    if not SOCIAL_CHAT_APP.exists():
        _msg(parent, 'Social global', f'No se encontro: {SOCIAL_CHAT_APP}')
        return
    cmd = []
    if PYRUN.exists() and os.access(str(PYRUN), os.X_OK):
        cmd = [str(PYRUN), str(SOCIAL_CHAT_APP)]
    else:
        cmd = ['python3', str(SOCIAL_CHAT_APP)]
    try:
        subprocess.call(cmd)
    except Exception as exc:
        _msg(parent, 'Social global', f'No se pudo abrir Social global:\n{exc}')


def _handle_action(action, parent):
    name = str(action or '').strip()
    if not name:
        _resume_paused()
        return
    if name == 'Reciente':
        _msg(parent, 'Reciente', _recent_text())
        _resume_paused()
        return
    if name == 'Mensajes recientes':
        _msg(parent, 'Mensajes recientes', _messages_text())
        _resume_paused()
        return
    if name == 'Social global':
        _launch_social_global(parent)
        _resume_paused()
        return
    if name == 'Descargas activas':
        _msg(parent, 'Descargas activas', _downloads_text())
        _resume_paused()
        return
    if name == 'Canjear codigo':
        res = _redeem_code(parent)
        if res:
            _msg(parent, 'Canjear codigo', res)
        _resume_paused()
        return
    if name == 'Cerrar app actual':
        subprocess.getoutput(f'/bin/sh -c "{CLOSE_SCRIPT}"')
        return
    if name == 'Cerrar sesion':
        _close_session()
        _msg(parent, 'Sesion', 'Sesion cerrada.')
        _activate_dashboard()
        _resume_paused()
        return
    if name == 'Logros':
        if _activate_dashboard():
            subprocess.getoutput('/bin/sh -lc "sleep 0.08; xdotool key --clearmodifiers F1 Return >/dev/null 2>&1 || true"')
        _resume_paused()
        return
    if name in ('Premios', 'Mis juegos', 'Configuracion', 'Inicio de Xbox'):
        _activate_dashboard()
        _resume_paused()
        return
    _resume_paused()


def main():
    DATA.mkdir(parents=True, exist_ok=True)
    now = int(time.time())
    if LOCK_FILE.exists():
        try:
            old = int((LOCK_FILE.read_text(encoding='utf-8', errors='ignore') or '0').strip() or '0')
            if now - old < 8:
                return 0
        except Exception:
            pass
    LOCK_FILE.write_text(str(now), encoding='utf-8')

    app = QtWidgets.QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(True)
    pid = _pick_target_pid()
    if pid:
        _pause_pid(pid)

    d = Guide(gamertag=_profile_gamertag(), paused_pid=pid)
    try:
        d.show()
    except Exception:
        d.show()
    accepted = d.exec_() == QtWidgets.QDialog.Accepted
    action = d.action if accepted else ''
    _handle_action(action, d)
    try:
        LOCK_FILE.unlink()
    except Exception:
        pass
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
PY
    chmod +x "$BIN_DIR/xui_global_guide.py"

    cat > "$BIN_DIR/xui_global_guide.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
PYRUN="$HOME/.xui/bin/xui_python.sh"
APP="$HOME/.xui/bin/xui_global_guide.py"
if command -v xdotool >/dev/null 2>&1; then
  wid="$(xdotool getactivewindow 2>/dev/null || true)"
  if [ -n "${wid:-}" ]; then
    pid="$(xdotool getwindowpid "$wid" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && [ -r "/proc/$pid/cmdline" ]; then
      cmdline="$(tr '\000' ' ' < "/proc/$pid/cmdline" | tr '[:upper:]' '[:lower:]')"
      if echo "$cmdline" | grep -Eq 'pyqt_dashboard_improved\.py|xui_startup_and_dashboard|xui-dashboard\.service'; then
        xdotool key --clearmodifiers F1 >/dev/null 2>&1 || true
        exit 0
      fi
    fi
  fi
fi
if [ -x "$PYRUN" ] && [ -f "$APP" ]; then
  exec "$PYRUN" "$APP" "$@"
fi
exec python3 "$APP" "$@"
BASH
    chmod +x "$BIN_DIR/xui_global_guide.sh"

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
import base64
import json
import os
import queue
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from PyQt5 import QtCore, QtGui, QtWidgets

XUI_HOME = Path.home() / '.xui'
DATA_HOME = XUI_HOME / 'data'
PROFILE_FILE = DATA_HOME / 'profile.json'
PEERS_FILE = DATA_HOME / 'social_peers.json'
WORLD_CHAT_FILE = DATA_HOME / 'world_chat.json'
SOCIAL_MESSAGES_FILE = DATA_HOME / 'social_messages_recent.json'
VOICE_DIR = DATA_HOME / 'social_voice'

DISCOVERY_PORT = int(os.environ.get('XUI_CHAT_DISCOVERY_PORT', '38655'))
CHAT_PORT_BASE = int(os.environ.get('XUI_CHAT_PORT', '38600'))
ANNOUNCE_INTERVAL = 2.5
MAX_TCP_PACKET_BYTES = int(os.environ.get('XUI_SOCIAL_MAX_PACKET_BYTES', str(4 * 1024 * 1024)))
DEFAULT_CALL_AUDIO_PORT = int(os.environ.get('XUI_CALL_AUDIO_PORT', '39700'))
DEFAULT_CALL_VIDEO_PORT = int(os.environ.get('XUI_CALL_VIDEO_PORT', '39701'))


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
        self.world_relay = os.environ.get('XUI_WORLD_RELAY_URL', 'https://ntfy.sh').strip().rstrip('/')
        self.world_topic = self._sanitize_topic(os.environ.get('XUI_WORLD_TOPIC', 'xui-world-global'))
        self.world_enabled = True
        self.events = queue.Queue()
        self.running = False
        self.threads = []
        self.peers = {}
        self.lock = threading.Lock()
        self.local_ips = set(list_local_ips())
        self._seen_world_ids = set()

    def _sanitize_topic(self, text):
        raw = ''.join(ch.lower() if ch.isalnum() or ch in ('-', '_', '.') else '-' for ch in str(text or '').strip())
        while '--' in raw:
            raw = raw.replace('--', '-')
        raw = raw.strip('-._')
        return raw or 'xui-world-global'

    def set_world_topic(self, topic):
        new_topic = self._sanitize_topic(topic)
        if new_topic == self.world_topic:
            return
        self.world_topic = new_topic
        self._seen_world_ids.clear()
        self.events.put(('world_room', self.world_topic))
        self.events.put(('status', f'World chat room set to: {self.world_topic}'))

    def set_world_enabled(self, enabled):
        self.world_enabled = bool(enabled)
        self.events.put(('world_status', self.world_enabled, self.world_topic))
        if self.world_enabled:
            self.events.put(('status', f'World chat connected: {self.world_topic}'))
        else:
            self.events.put(('status', 'World chat disconnected'))

    def start(self):
        self.running = True
        for target in (
            self._tcp_server_loop,
            self._discovery_listener_loop,
            self._discovery_sender_loop,
            self._peer_gc_loop,
            self._world_recv_loop,
        ):
            t = threading.Thread(target=target, daemon=True)
            self.threads.append(t)
            t.start()
        if self.chat_port:
            self.events.put(('status', f'Chat TCP listening on port {self.chat_port}'))
        else:
            self.events.put(('status', 'No free TCP chat port found.'))
        self.events.put(('world_status', self.world_enabled, self.world_topic))

    def stop(self):
        self.running = False
        for t in self.threads:
            t.join(timeout=0.2)

    def _send_packet(self, host, port, payload):
        body = (json.dumps(payload, ensure_ascii=False) + '\n').encode('utf-8', errors='ignore')
        with socket.create_connection((str(host), int(port)), timeout=4) as s:
            s.sendall(body)

    def send_chat(self, host, port, text):
        payload = {
            'type': 'chat',
            'node_id': self.node_id,
            'from': self.nickname,
            'text': text,
            'ts': time.time(),
            'reply_port': self.chat_port,
        }
        self._send_packet(host, port, payload)

    def send_voice_message(self, host, port, mime, duration_sec, blob):
        raw = bytes(blob or b'')
        if not raw:
            return
        payload = {
            'type': 'voice_message',
            'node_id': self.node_id,
            'from': self.nickname,
            'mime': str(mime or 'audio/ogg'),
            'duration': float(duration_sec or 0.0),
            'voice_b64': base64.b64encode(raw).decode('ascii', errors='ignore'),
            'ts': time.time(),
            'reply_port': self.chat_port,
        }
        self._send_packet(host, port, payload)

    def send_call_invite(self, host, port, mode='voice', audio_port=DEFAULT_CALL_AUDIO_PORT, video_port=DEFAULT_CALL_VIDEO_PORT, note=''):
        payload = {
            'type': 'call_invite',
            'node_id': self.node_id,
            'from': self.nickname,
            'mode': str(mode or 'voice'),
            'audio_port': int(audio_port or DEFAULT_CALL_AUDIO_PORT),
            'video_port': int(video_port or DEFAULT_CALL_VIDEO_PORT),
            'note': str(note or ''),
            'ts': time.time(),
            'reply_port': self.chat_port,
        }
        self._send_packet(host, port, payload)

    def _world_url(self, suffix=''):
        topic = urllib.parse.quote(self.world_topic, safe='')
        return f'{self.world_relay}/{topic}{suffix}'

    def send_world_chat(self, text):
        msg = {
            'kind': 'xui_world_chat',
            'node_id': self.node_id,
            'from': self.nickname,
            'text': str(text or ''),
            'room': self.world_topic,
            'ts': time.time(),
        }
        data = json.dumps(msg, ensure_ascii=False).encode('utf-8', errors='ignore')
        req = urllib.request.Request(
            self._world_url(''),
            data=data,
            method='POST',
            headers={
                'Content-Type': 'text/plain; charset=utf-8',
                'User-Agent': 'xui-social-global-chat',
                'X-Title': f'XUI:{self.nickname}',
            },
        )
        with urllib.request.urlopen(req, timeout=8) as r:
            _ = r.read(256)

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
                chunks = []
                total = 0
                try:
                    while True:
                        part = conn.recv(65536)
                        if not part:
                            break
                        chunks.append(part)
                        total += len(part)
                        if total > MAX_TCP_PACKET_BYTES:
                            chunks = []
                            break
                    payload = b''.join(chunks).decode('utf-8', errors='ignore') if chunks else ''
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
                mtype = str(msg.get('type') or '')
                if mtype not in ('chat', 'voice_message', 'call_invite'):
                    continue
                name = str(msg.get('from') or host)
                sender_node = str(msg.get('node_id') or '')
                try:
                    reply_port = int(msg.get('reply_port') or 0)
                except Exception:
                    reply_port = 0
                if reply_port > 0:
                    self._push_peer(name, host, reply_port, 'LAN', sender_node)
                if mtype == 'call_invite':
                    mode = str(msg.get('mode') or 'voice').strip().lower()
                    try:
                        audio_port = int(msg.get('audio_port') or DEFAULT_CALL_AUDIO_PORT)
                    except Exception:
                        audio_port = DEFAULT_CALL_AUDIO_PORT
                    try:
                        video_port = int(msg.get('video_port') or DEFAULT_CALL_VIDEO_PORT)
                    except Exception:
                        video_port = DEFAULT_CALL_VIDEO_PORT
                    note = str(msg.get('note') or '').strip()
                    self.events.put(('call_invite', name, host, int(reply_port or 0), mode, audio_port, video_port, note))
                    continue
                if mtype == 'voice_message':
                    b64 = str(msg.get('voice_b64') or '').strip()
                    if not b64 or len(b64) > (MAX_TCP_PACKET_BYTES * 2):
                        continue
                    mime = str(msg.get('mime') or 'audio/ogg').strip()
                    try:
                        duration = float(msg.get('duration') or 0.0)
                    except Exception:
                        duration = 0.0
                    try:
                        blob = base64.b64decode(b64.encode('ascii', errors='ignore'), validate=False)
                    except Exception:
                        blob = b''
                    if blob:
                        self.events.put(('voice_message', name, host, int(reply_port or 0), mime, duration, blob))
                    continue
                text = str(msg.get('text') or '').strip()
                if text:
                    self.events.put(('chat', name, host, reply_port, text, float(msg.get('ts') or time.time())))
        srv.close()

    def _world_recv_loop(self):
        backoff = 1.2
        while self.running:
            if not self.world_enabled:
                time.sleep(0.4)
                continue
            req = urllib.request.Request(
                self._world_url('/json'),
                headers={
                    'User-Agent': 'xui-social-global-chat',
                    'Cache-Control': 'no-cache',
                    'Connection': 'keep-alive',
                },
            )
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    backoff = 1.2
                    while self.running and self.world_enabled:
                        raw = resp.readline()
                        if not raw:
                            break
                        line = raw.decode('utf-8', errors='ignore').strip()
                        if not line:
                            continue
                        try:
                            evt = json.loads(line)
                        except Exception:
                            continue
                        if str(evt.get('event') or '') != 'message':
                            continue
                        msg_id = str(evt.get('id') or '')
                        if msg_id:
                            if msg_id in self._seen_world_ids:
                                continue
                            self._seen_world_ids.add(msg_id)
                            if len(self._seen_world_ids) > 1200:
                                self._seen_world_ids = set(list(self._seen_world_ids)[-600:])
                        body = str(evt.get('message') or '').strip()
                        if not body:
                            continue
                        try:
                            payload = json.loads(body)
                        except Exception:
                            payload = {
                                'kind': 'xui_world_chat',
                                'node_id': '',
                                'from': str(evt.get('title') or 'WORLD'),
                                'text': body,
                                'room': self.world_topic,
                                'ts': evt.get('time', time.time()),
                            }
                        if str(payload.get('kind') or '') != 'xui_world_chat':
                            continue
                        if str(payload.get('room') or self.world_topic) != self.world_topic:
                            continue
                        if str(payload.get('node_id') or '') == self.node_id:
                            continue
                        who = str(payload.get('from') or 'WORLD')
                        txt = str(payload.get('text') or '').strip()
                        if txt:
                            self.events.put(('world_chat', who, txt))
            except Exception as exc:
                self.events.put(('status', f'World relay reconnecting: {exc}'))
                time.sleep(min(8.0, backoff))
                backoff = min(8.0, backoff * 1.5)


class VirtualKeyboardDialog(QtWidgets.QDialog):
    def __init__(self, initial='', parent=None):
        super().__init__(parent)
        self._nav_default_cols = 10
        self.setWindowTitle('Virtual Keyboard')
        self.setWindowFlags(QtCore.Qt.Dialog | QtCore.Qt.FramelessWindowHint)
        self.setModal(True)
        self.resize(920, 420)
        self.setStyleSheet('''
            QDialog { background:#d2d7dc; border:2px solid #e8edf1; }
            QLineEdit { background:#ffffff; border:1px solid #8a96a3; color:#1e2731; font-size:24px; font-weight:700; padding:8px; }
            QListWidget { background:#eef2f5; border:1px solid #9da8b3; color:#24303b; font-size:18px; font-weight:800; outline:none; }
            QListWidget::item { border:1px solid #c1c9d2; min-width:74px; min-height:46px; margin:4px; }
            QListWidget::item:selected { background:#66b340; color:#fff; border:2px solid #2f6e28; }
            QLabel { color:#2f3944; font-size:14px; font-weight:700; }
        ''')
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(12, 10, 12, 10)
        v.setSpacing(8)
        self.edit = QtWidgets.QLineEdit(str(initial or ''))
        self.edit.setFocusPolicy(QtCore.Qt.ClickFocus)
        self.edit.installEventFilter(self)
        v.addWidget(self.edit)
        self.keys = QtWidgets.QListWidget()
        self.keys.setViewMode(QtWidgets.QListView.IconMode)
        self.keys.setMovement(QtWidgets.QListView.Static)
        self.keys.setResizeMode(QtWidgets.QListView.Adjust)
        self.keys.setWrapping(True)
        self.keys.setSpacing(4)
        self.keys.setGridSize(QtCore.QSize(84, 54))
        self.keys.itemActivated.connect(self._activate_current)
        self.keys.installEventFilter(self)
        tokens = list('1234567890QWERTYUIOPASDFGHJKLZXCVBNM') + ['-', '_', '@', '.', '/', ':', 'SPACE', 'BACK', 'CLEAR', 'DONE']
        for token in tokens:
            self.keys.addItem(QtWidgets.QListWidgetItem(token))
        self.keys.setCurrentRow(0)
        self.keys.setFocus(QtCore.Qt.OtherFocusReason)
        v.addWidget(self.keys, 1)
        v.addWidget(QtWidgets.QLabel('A/ENTER = Select | B/ESC = Back | X = Backspace | Y = Space'))

    def text(self):
        return self.edit.text()

    def _activate_current(self):
        it = self.keys.currentItem()
        if it is None:
            return
        key = str(it.text() or '')
        if key == 'DONE':
            self.accept()
            return
        if key == 'SPACE':
            self.edit.setText(self.edit.text() + ' ')
            self.keys.setFocus(QtCore.Qt.OtherFocusReason)
            return
        if key == 'BACK':
            self.edit.setText(self.edit.text()[:-1])
            self.keys.setFocus(QtCore.Qt.OtherFocusReason)
            return
        if key == 'CLEAR':
            self.edit.setText('')
            self.keys.setFocus(QtCore.Qt.OtherFocusReason)
            return
        self.edit.setText(self.edit.text() + key)
        self.keys.setFocus(QtCore.Qt.OtherFocusReason)

    def _nav_cols(self):
        try:
            grid_w = int(self.keys.gridSize().width())
            view_w = int(self.keys.viewport().width())
            return max(1, view_w // max(1, grid_w))
        except Exception:
            return self._nav_default_cols

    def _move_selection(self, dr=0, dc=0):
        total = int(self.keys.count())
        if total <= 0:
            return
        cols = max(1, int(self._nav_cols() or self._nav_default_cols))
        idx = int(self.keys.currentRow())
        if idx < 0:
            idx = 0
        row = idx // cols
        col = idx % cols
        row += int(dr)
        col += int(dc)
        max_row = (total - 1) // cols
        row = max(0, min(max_row, row))
        col = max(0, col)
        row_start = row * cols
        row_end = min(total - 1, row_start + cols - 1)
        new_idx = min(row_end, row_start + col)
        self.keys.setCurrentRow(new_idx)
        it = self.keys.currentItem()
        if it is not None:
            self.keys.scrollToItem(it, QtWidgets.QAbstractItemView.PositionAtCenter)

    def eventFilter(self, obj, event):
        if event.type() == QtCore.QEvent.KeyPress:
            if event.key() in (
                QtCore.Qt.Key_Left, QtCore.Qt.Key_Right,
                QtCore.Qt.Key_Up, QtCore.Qt.Key_Down,
                QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter,
                QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back,
                QtCore.Qt.Key_Space, QtCore.Qt.Key_Backspace,
            ):
                self.keyPressEvent(event)
                return True
        return super().eventFilter(obj, event)

    def keyPressEvent(self, e):
        k = e.key()
        if k == QtCore.Qt.Key_Left:
            self._move_selection(0, -1)
            return
        if k == QtCore.Qt.Key_Right:
            self._move_selection(0, 1)
            return
        if k == QtCore.Qt.Key_Up:
            self._move_selection(-1, 0)
            return
        if k == QtCore.Qt.Key_Down:
            self._move_selection(1, 0)
            return
        if k in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_Back):
            self.reject()
            return
        if k in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter):
            self._activate_current()
            return
        if k == QtCore.Qt.Key_Space:
            self.edit.setText(self.edit.text() + ' ')
            self.keys.setFocus(QtCore.Qt.OtherFocusReason)
            return
        if k == QtCore.Qt.Key_Backspace:
            self.edit.setText(self.edit.text()[:-1])
            self.keys.setFocus(QtCore.Qt.OtherFocusReason)
            return
        super().keyPressEvent(e)


class SocialChatWindow(QtWidgets.QWidget):
    def __init__(self):
        super().__init__()
        DATA_HOME.mkdir(parents=True, exist_ok=True)
        VOICE_DIR.mkdir(parents=True, exist_ok=True)
        self.nickname = load_gamertag()
        self.setWindowTitle(f'XUI Social Chat - {self.nickname}')
        self.resize(1180, 720)
        self.engine = SocialNetworkEngine(self.nickname)
        self.peer_items = {}
        self.peer_data = {}
        self.voice_inbox = []
        self.last_call_invite = None
        self.call_procs = []
        self.call_active = False
        self._vk_opening = False
        self._vk_last_close = 0.0
        self._action_items = {}
        self._build_ui()
        self._load_manual_peers()
        self._load_world_settings()
        self.engine.start()
        self._refresh_world_peer()
        self.timer = QtCore.QTimer(self)
        self.timer.timeout.connect(self._poll_events)
        self.timer.start(120)
        self._append_system('LAN autodiscovery enabled (broadcast + probe). Add manual peer for Internet P2P.')
        self._append_system(f"World chat ready via relay ({self.engine.world_relay}) room: {self.engine.world_topic}")

    def _build_ui(self):
        self.setStyleSheet('''
            QWidget { background:#242b33; color:#edf3f8; font-size:15px; }
            QFrame#social_col {
                background:rgba(52,61,72,0.94);
                border:1px solid rgba(196,208,222,0.30);
            }
            QLabel#social_title { color:#edf4fa; font-size:22px; font-weight:800; }
            QLabel#social_hint { color:rgba(234,242,248,0.84); font-size:15px; }
            QListWidget {
                background:rgba(236,239,242,0.92);
                color:#20252b;
                border:1px solid rgba(0,0,0,0.26);
                font-size:23px;
                outline:none;
            }
            QListWidget::item {
                padding:6px 10px;
                border:1px solid transparent;
            }
            QListWidget::item:selected {
                color:#f3fff2;
                background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #4ea93f, stop:1 #2f8832);
                border:1px solid rgba(255,255,255,0.25);
            }
            QPlainTextEdit {
                background:rgba(228,233,238,0.96);
                border:1px solid rgba(32,39,48,0.28);
                color:#17202a;
                font-size:18px;
            }
            QLineEdit {
                background:#eef2f6;
                border:1px solid #8fa0b1;
                color:#17202a;
                font-size:21px;
                font-weight:700;
                padding:8px;
            }
            QPushButton {
                background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #4ea93f, stop:1 #2f8832);
                border:1px solid rgba(238,246,236,0.40);
                color:#eefaf0;
                padding:8px 12px;
                font-weight:700;
            }
            QPushButton:hover { background:#58b449; }
        ''')
        root = QtWidgets.QVBoxLayout(self)
        root.setContentsMargins(10, 10, 10, 10)
        root.setSpacing(8)

        top = QtWidgets.QHBoxLayout()
        self.title = QtWidgets.QLabel('social / messages')
        self.title.setObjectName('social_title')
        self.gamer = QtWidgets.QLabel(f'gamertag: {self.nickname}')
        self.gamer.setObjectName('social_hint')
        top.addWidget(self.title)
        top.addStretch(1)
        top.addWidget(self.gamer)
        root.addLayout(top)

        body = QtWidgets.QHBoxLayout()
        body.setSpacing(10)

        left_wrap = QtWidgets.QFrame()
        left_wrap.setObjectName('social_col')
        left = QtWidgets.QVBoxLayout(left_wrap)
        left.setContentsMargins(8, 8, 8, 8)
        left.setSpacing(6)
        left_title = QtWidgets.QLabel('Messages / Peers')
        left_title.setObjectName('social_title')
        self.peer_list = QtWidgets.QListWidget()
        self.peer_list.setMinimumWidth(340)
        self.peer_list.currentItemChanged.connect(lambda *_: self._update_peer_meta())

        left.addWidget(left_title)
        left.addWidget(self.peer_list, 1)

        center_wrap = QtWidgets.QFrame()
        center_wrap.setObjectName('social_col')
        center = QtWidgets.QVBoxLayout(center_wrap)
        center.setContentsMargins(8, 8, 8, 8)
        center.setSpacing(6)
        center_title = QtWidgets.QLabel('Actions')
        center_title.setObjectName('social_title')
        self.actions = QtWidgets.QListWidget()
        self.actions.setMinimumWidth(290)
        center.addWidget(center_title)
        center.addWidget(self.actions, 1)
        self.actions.itemActivated.connect(self._run_selected_action)
        self.actions.itemDoubleClicked.connect(self._run_selected_action)

        right_wrap = QtWidgets.QFrame()
        right_wrap.setObjectName('social_col')
        right = QtWidgets.QVBoxLayout(right_wrap)
        right.setContentsMargins(8, 8, 8, 8)
        right.setSpacing(6)
        right_title = QtWidgets.QLabel('Message Detail')
        right_title.setObjectName('social_title')
        self.peer_meta = QtWidgets.QLabel('Select a peer to chat.')
        self.peer_meta.setObjectName('social_hint')
        self.chat = QtWidgets.QPlainTextEdit()
        self.chat.setReadOnly(True)
        self.chat.setLineWrapMode(QtWidgets.QPlainTextEdit.WidgetWidth)
        self.msg = QtWidgets.QLineEdit()
        self.msg.setPlaceholderText('Press A/ENTER to type message...')
        self.msg.installEventFilter(self)
        self.btn_send = QtWidgets.QPushButton('Send')
        self.btn_send.clicked.connect(self._send_current)
        self.msg.returnPressed.connect(self._send_current)
        self.status = QtWidgets.QLabel('Ready')
        self.status.setObjectName('social_hint')

        bottom = QtWidgets.QHBoxLayout()
        bottom.addWidget(self.msg, 1)
        bottom.addWidget(self.btn_send)

        right.addWidget(right_title)
        right.addWidget(self.peer_meta)
        right.addWidget(self.chat, 1)
        right.addLayout(bottom)
        right.addWidget(self.status)

        body.addWidget(left_wrap, 3)
        body.addWidget(center_wrap, 2)
        body.addWidget(right_wrap, 5)
        root.addLayout(body, 1)

        self._add_action_item('reply', 'Reply / Send Message')
        self._add_action_item('voice_msg', 'Send Voice Message')
        self._add_action_item('voice_inbox', 'Voice Inbox')
        self._add_action_item('call_voice', 'Start Voice Call')
        self._add_action_item('call_screen', 'Voice Call + Screen')
        self._add_action_item('call_join', 'Join Last Invite')
        self._add_action_item('call_stop', 'Stop Current Call')
        self._add_action_item('add_peer', 'Add Peer ID')
        self._add_action_item('peer_ids', 'My Peer IDs')
        self._add_action_item('lan_status', 'LAN Status')
        self._add_action_item('world_toggle', 'World Chat: ON')
        self._add_action_item('world_room', 'World Room')
        if self.actions.count() > 0:
            self.actions.setCurrentRow(0)

        hint = QtWidgets.QLabel('A/ENTER = select | B/ESC = close | Text input opens virtual keyboard')
        hint.setObjectName('social_hint')
        root.addWidget(hint)

    def _add_action_item(self, key, text):
        it = QtWidgets.QListWidgetItem(str(text))
        it.setData(QtCore.Qt.UserRole, str(key))
        self.actions.addItem(it)
        self._action_items[str(key)] = it

    def _run_selected_action(self, *_):
        it = self.actions.currentItem()
        if it is None:
            return
        key = str(it.data(QtCore.Qt.UserRole) or '').strip()
        if key == 'reply':
            self.msg.setFocus(QtCore.Qt.OtherFocusReason)
            self._open_chat_keyboard()
            return
        if key == 'voice_msg':
            self._send_voice_message()
            return
        if key == 'voice_inbox':
            self._open_voice_inbox()
            return
        if key == 'call_voice':
            self._start_p2p_call(with_screen=False)
            return
        if key == 'call_screen':
            self._start_p2p_call(with_screen=True)
            return
        if key == 'call_join':
            self._join_last_call_invite()
            return
        if key == 'call_stop':
            self._stop_call_session(notify=True)
            return
        if key == 'add_peer':
            self._add_peer_dialog()
            return
        if key == 'peer_ids':
            self._show_my_peer_ids()
            return
        if key == 'lan_status':
            self._show_lan_status()
            return
        if key == 'world_toggle':
            self._toggle_world_chat()
            return
        if key == 'world_room':
            self._change_world_room()
            return

    def _update_peer_meta(self):
        peer = self._current_peer()
        if not peer:
            self.peer_meta.setText('Select a peer to chat.')
            return
        if str(peer.get('source')) == 'WORLD':
            self.peer_meta.setText(f"WORLD relay room #{self.engine.world_topic}")
            return
        name = str(peer.get('name') or 'Peer')
        host = str(peer.get('host') or '-')
        port = int(peer.get('port') or 0)
        src = str(peer.get('source') or 'LAN')
        self.peer_meta.setText(f'{name}  [{host}:{port}]  ({src})')

    def _open_chat_keyboard(self):
        if self._vk_opening:
            return
        if (time.monotonic() - float(self._vk_last_close)) < 0.35:
            return
        self._vk_opening = True
        try:
            d = VirtualKeyboardDialog(self.msg.text(), self)
            if d.exec_() == QtWidgets.QDialog.Accepted:
                self.msg.setText(d.text())
        finally:
            self._vk_last_close = time.monotonic()
            self._vk_opening = False
            self.msg.setFocus(QtCore.Qt.OtherFocusReason)

    def eventFilter(self, obj, event):
        if obj is self.msg:
            et = event.type()
            if et in (QtCore.QEvent.FocusIn, QtCore.QEvent.MouseButtonPress):
                if not self._vk_opening and (time.monotonic() - float(self._vk_last_close)) >= 0.35:
                    QtCore.QTimer.singleShot(0, self._open_chat_keyboard)
        return super().eventFilter(obj, event)

    def _peer_row_text(self, p):
        if str(p.get('source')) == 'WORLD':
            return f"{p['name']}  [global relay]  (WORLD)"
        return f"{p['name']}  [{p['host']}:{p['port']}]  ({p['source']})"

    def _upsert_peer(self, name, host, port, source='LAN', node_id='', persist=False):
        key = f'{host}:{int(port)}'
        data = {
            'name': (name or host).strip() or host,
            'host': host,
            'port': int(port),
            'source': source,
            'node_id': str(node_id or ''),
            '_world': bool(str(source) == 'WORLD'),
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
        self._update_peer_meta()
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
        self._update_peer_meta()

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
        self._push_recent_message(sender, text)

    def _push_recent_message(self, who, text):
        who_txt = str(who or '').strip() or 'Unknown'
        body = str(text or '').strip()
        if not body:
            return
        arr = safe_json_read(SOCIAL_MESSAGES_FILE, [])
        if not isinstance(arr, list):
            arr = []
        arr.insert(0, {'ts': int(time.time()), 'from': who_txt[:48], 'text': body[:320]})
        safe_json_write(SOCIAL_MESSAGES_FILE, arr[:80])

    def _current_peer(self):
        item = self.peer_list.currentItem()
        if not item:
            return None
        key = item.data(QtCore.Qt.UserRole)
        return self.peer_data.get(key)

    def _world_peer_payload(self):
        return {
            'name': f'WORLD #{self.engine.world_topic}',
            'host': self.engine.world_relay,
            'port': 0,
            'source': 'WORLD',
            'node_id': f'world:{self.engine.world_topic}',
            '_world': True,
        }

    def _refresh_world_peer(self):
        stale = []
        for key, peer in self.peer_data.items():
            if str(peer.get('source')) == 'WORLD' or bool(peer.get('_world')):
                stale.append(key)
        for key in stale:
            self._remove_peer(key)
        if self.engine.world_enabled:
            p = self._world_peer_payload()
            self._upsert_peer(p['name'], p['host'], p['port'], p['source'], p['node_id'], persist=False)
            world_key = f"{p['host']}:{int(p['port'])}"
            if world_key in self.peer_data:
                self.peer_data[world_key]['_world'] = True
        self._update_world_toggle_button()

    def _update_world_toggle_button(self):
        it = self._action_items.get('world_toggle')
        if it is None:
            return
        if self.engine.world_enabled:
            it.setText('World Chat: ON')
        else:
            it.setText('World Chat: OFF')

    def _load_world_settings(self):
        cfg = safe_json_read(WORLD_CHAT_FILE, {})
        room = str(cfg.get('room', '')).strip()
        enabled = bool(cfg.get('enabled', True))
        if room:
            self.engine.set_world_topic(room)
        self.engine.set_world_enabled(enabled)
        self._update_world_toggle_button()

    def _save_world_settings(self):
        safe_json_write(
            WORLD_CHAT_FILE,
            {
                'room': self.engine.world_topic,
                'enabled': bool(self.engine.world_enabled),
                'relay': self.engine.world_relay,
            },
        )

    def _toggle_world_chat(self):
        self.engine.set_world_enabled(not self.engine.world_enabled)
        self._refresh_world_peer()
        self._save_world_settings()

    def _change_world_room(self):
        txt, ok = QtWidgets.QInputDialog.getText(
            self,
            'World Chat Room',
            'Room/topic name (letters, numbers, -, _, .)',
            text=self.engine.world_topic,
        )
        if not ok:
            return
        self.engine.set_world_topic(txt)
        self._refresh_world_peer()
        self._save_world_settings()
        self._append_system(f'World room changed to: {self.engine.world_topic}')

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
            if str(p.get('source') or '') == 'WORLD':
                continue
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
            QtWidgets.QMessageBox.information(self, 'Peer required', 'Select a peer first.')
            return
        text = self.msg.text().strip()
        if not text:
            return
        if str(peer.get('source')) == 'WORLD':
            try:
                self.engine.send_world_chat(text)
                hhmm = time.strftime('%H:%M:%S')
                self._append_line(f'[{hhmm}] You -> WORLD: {text}')
                self._push_recent_message('You -> WORLD', text)
                self.status.setText(f'World sent to room {self.engine.world_topic}')
                self.msg.clear()
            except Exception as exc:
                self.status.setText(f'World send failed: {exc}')
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
        lines += ['', f'World room: {self.engine.world_topic}', f'World relay: {self.engine.world_relay}']
        lines += [f'Call audio UDP port (default): {DEFAULT_CALL_AUDIO_PORT}']
        lines += [f'Call screen UDP port (default): {DEFAULT_CALL_VIDEO_PORT}']
        lines += ['', 'Tip: for Internet P2P use Tailscale/ZeroTier or router port-forward TCP 38600.']
        QtWidgets.QMessageBox.information(self, 'My Peer IDs', '\n'.join(lines))

    def _show_lan_status(self):
        out = subprocess.getoutput('/bin/sh -c "$HOME/.xui/bin/xui_lan_status.sh"')
        QtWidgets.QMessageBox.information(self, 'LAN Status', out or 'No network data.')

    def _record_voice_clip(self, duration_sec):
        secs = max(1, min(int(duration_sec), 25))
        tmp_ogg = Path(tempfile.mktemp(prefix='xui_voice_', suffix='.ogg'))
        tmp_wav = Path(tempfile.mktemp(prefix='xui_voice_', suffix='.wav'))
        try:
            if shutil.which('ffmpeg'):
                candidates = [
                    ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'pulse', '-i', 'default',
                     '-t', str(secs), '-ac', '1', '-ar', '16000', '-c:a', 'libopus', '-b:a', '32k', str(tmp_ogg)],
                    ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'alsa', '-i', 'default',
                     '-t', str(secs), '-ac', '1', '-ar', '16000', '-c:a', 'libopus', '-b:a', '32k', str(tmp_ogg)],
                ]
                for cmd in candidates:
                    rc = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
                    if rc == 0 and tmp_ogg.exists() and tmp_ogg.stat().st_size > 1024:
                        return (tmp_ogg.read_bytes(), 'audio/ogg', float(secs), '')
            if shutil.which('arecord'):
                cmd = [
                    'arecord', '-q', '-d', str(secs), '-f', 'S16_LE', '-r', '16000', '-c', '1', str(tmp_wav)
                ]
                rc = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
                if rc == 0 and tmp_wav.exists() and tmp_wav.stat().st_size > 2048:
                    return (tmp_wav.read_bytes(), 'audio/wav', float(secs), '')
            return (b'', '', 0.0, 'No recording backend (ffmpeg/arecord).')
        except Exception as exc:
            return (b'', '', 0.0, str(exc))
        finally:
            try:
                tmp_ogg.unlink(missing_ok=True)
            except Exception:
                pass
            try:
                tmp_wav.unlink(missing_ok=True)
            except Exception:
                pass

    def _voice_file_suffix(self, mime):
        m = str(mime or '').lower()
        if 'wav' in m:
            return '.wav'
        if 'ogg' in m or 'opus' in m:
            return '.ogg'
        return '.bin'

    def _save_voice_blob(self, sender, mime, duration, blob):
        ts = int(time.time())
        safe_sender = ''.join(ch if ch.isalnum() or ch in ('-', '_') else '_' for ch in str(sender or 'peer'))[:28]
        path = VOICE_DIR / f'voice_{ts}_{safe_sender}{self._voice_file_suffix(mime)}'
        try:
            path.write_bytes(bytes(blob or b''))
        except Exception:
            return None
        item = {
            'sender': str(sender or 'Unknown'),
            'mime': str(mime or 'audio/ogg'),
            'duration': float(duration or 0.0),
            'path': str(path),
            'ts': ts,
        }
        self.voice_inbox.insert(0, item)
        self.voice_inbox = self.voice_inbox[:80]
        return item

    def _play_voice_file(self, path):
        p = str(path or '').strip()
        if not p or not Path(p).exists():
            self.status.setText('Voice file not found.')
            return
        if shutil.which('mpv'):
            subprocess.Popen(['mpv', '--really-quiet', '--no-terminal', p], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
        if shutil.which('ffplay'):
            subprocess.Popen(['ffplay', '-nodisp', '-autoexit', '-loglevel', 'quiet', p], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
        if shutil.which('aplay'):
            subprocess.Popen(['aplay', p], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
        self.status.setText('No audio player found (mpv/ffplay/aplay).')

    def _open_voice_inbox(self):
        if not self.voice_inbox:
            QtWidgets.QMessageBox.information(self, 'Voice Inbox', 'No voice messages yet.')
            return
        lines = []
        for i, msg in enumerate(self.voice_inbox[:30], 1):
            hh = time.strftime('%H:%M:%S', time.localtime(int(msg.get('ts') or time.time())))
            who = str(msg.get('sender') or 'Unknown')
            dur = float(msg.get('duration') or 0.0)
            lines.append(f'{i}. {who} ({dur:.0f}s) [{hh}]')
        idx, ok = QtWidgets.QInputDialog.getInt(
            self,
            'Voice Inbox',
            'Select voice message number to play:\n\n' + '\n'.join(lines),
            1,
            1,
            len(lines),
            1,
        )
        if not ok:
            return
        sel = self.voice_inbox[int(idx) - 1]
        self._play_voice_file(sel.get('path'))
        self.status.setText(f"Playing voice from {sel.get('sender', 'Unknown')}")

    def _send_voice_message(self):
        peer = self._current_peer()
        if not peer or str(peer.get('source')) == 'WORLD':
            QtWidgets.QMessageBox.information(self, 'Voice Message', 'Select a LAN/P2P peer first.')
            return
        seconds, ok = QtWidgets.QInputDialog.getInt(
            self, 'Voice Message', 'Duration seconds:', 6, 2, 20, 1
        )
        if not ok:
            return
        self.status.setText(f'Recording voice message ({seconds}s)...')
        QtWidgets.QApplication.processEvents()
        blob, mime, duration, err = self._record_voice_clip(int(seconds))
        if not blob:
            self.status.setText(f'Voice record failed: {err}')
            return
        candidates = self._send_candidates(peer)
        last_err = None
        used = None
        for host, port, key in candidates:
            try:
                self.engine.send_voice_message(host, port, mime, duration, blob)
                used = (host, int(port), key)
                break
            except Exception as exc:
                last_err = exc
        if not used:
            self.status.setText(f'Voice send failed: {last_err or "unreachable peer"}')
            return
        host, port, key = used
        self._append_line(f"[{time.strftime('%H:%M:%S')}] You -> {peer.get('name','peer')} [VOICE {duration:.0f}s]")
        self._push_recent_message(f"You -> {peer.get('name', 'peer')} [VOICE]", f'Voice message ({duration:.0f}s)')
        if host == str(peer.get('host')) and int(port) == int(peer.get('port') or 0):
            self.status.setText(f'Voice sent to {host}:{port}')
        else:
            self.status.setText(f'Voice sent via fallback {host}:{port}')
            item = self.peer_items.get(key)
            if item is not None:
                self.peer_list.setCurrentItem(item)

    def _spawn_call_proc(self, cmd):
        try:
            p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.call_procs.append(p)
            return True
        except Exception:
            return False

    def _stop_call_session(self, notify=False):
        any_proc = False
        for p in list(self.call_procs):
            try:
                p.terminate()
            except Exception:
                pass
            any_proc = True
        self.call_procs = []
        self.call_active = False
        if notify:
            self.status.setText('Call session stopped.' if any_proc else 'No active call session.')

    def _launch_call_session(self, remote_host, audio_port, video_port, with_screen=False):
        host = str(remote_host or '').strip()
        if not host:
            self.status.setText('Invalid call host.')
            return False
        a_port = int(audio_port or DEFAULT_CALL_AUDIO_PORT)
        v_port = int(video_port or DEFAULT_CALL_VIDEO_PORT)
        if not shutil.which('ffmpeg') or not shutil.which('ffplay'):
            self.status.setText('Call requires ffmpeg + ffplay installed.')
            return False
        self._stop_call_session(notify=False)
        ok_recv_audio = self._spawn_call_proc([
            'ffplay', '-nodisp', '-fflags', 'nobuffer', '-flags', 'low_delay', '-loglevel', 'quiet',
            f'udp://0.0.0.0:{a_port}?listen=1'
        ])
        send_audio_cmd = (
            f'ffmpeg -hide_banner -loglevel error -f pulse -i default -ac 1 -ar 16000 -c:a libopus -b:a 48k '
            f'-f mpegts udp://{host}:{a_port}?pkt_size=1316 '
            f'|| ffmpeg -hide_banner -loglevel error -f alsa -i default -ac 1 -ar 16000 -c:a libopus -b:a 48k '
            f'-f mpegts udp://{host}:{a_port}?pkt_size=1316'
        )
        ok_send_audio = self._spawn_call_proc(['/bin/sh', '-lc', send_audio_cmd])
        ok = bool(ok_recv_audio and ok_send_audio)
        if with_screen:
            ok_recv_video = self._spawn_call_proc([
                'ffplay', '-fflags', 'nobuffer', '-flags', 'low_delay', '-loglevel', 'quiet',
                f'udp://0.0.0.0:{v_port}?listen=1'
            ])
            disp = os.environ.get('DISPLAY', ':0')
            send_video_cmd = (
                f'ffmpeg -hide_banner -loglevel error -f x11grab -framerate 20 -video_size 1280x720 '
                f'-i {disp}.0 -pix_fmt yuv420p -vcodec libx264 -preset ultrafast -tune zerolatency '
                f'-f mpegts udp://{host}:{v_port}?pkt_size=1316'
            )
            ok_send_video = self._spawn_call_proc(['/bin/sh', '-lc', send_video_cmd])
            ok = bool(ok and ok_recv_video and ok_send_video)
        self.call_active = ok
        return ok

    def _start_p2p_call(self, with_screen=False):
        peer = self._current_peer()
        if not peer or str(peer.get('source')) == 'WORLD':
            QtWidgets.QMessageBox.information(self, 'P2P Call', 'Select a LAN/P2P peer first.')
            return
        host = str(peer.get('host') or '').strip()
        if not host:
            self.status.setText('Invalid peer host.')
            return
        audio_port = DEFAULT_CALL_AUDIO_PORT
        video_port = DEFAULT_CALL_VIDEO_PORT
        mode = 'voice_screen' if with_screen else 'voice'
        started = self._launch_call_session(host, audio_port, video_port, with_screen=with_screen)
        if not started:
            self.status.setText('Could not start call session (check ffmpeg/ffplay/mic/display).')
            return
        self.status.setText(f'Call started with {peer.get("name", host)} ({mode})')
        self._append_system(f'Call session started with {peer.get("name", host)} ({mode}).')
        candidates = self._send_candidates(peer)
        for c_host, c_port, _key in candidates:
            try:
                self.engine.send_call_invite(
                    c_host, c_port, mode=mode, audio_port=audio_port, video_port=video_port,
                    note=f'{self.nickname} started a {mode} call'
                )
                break
            except Exception:
                continue

    def _join_last_call_invite(self):
        inv = self.last_call_invite
        if not inv:
            QtWidgets.QMessageBox.information(self, 'Join Call', 'No incoming call invite yet.')
            return
        host = str(inv.get('host') or '').strip()
        if not host:
            self.status.setText('Invalid invite host.')
            return
        mode = str(inv.get('mode') or 'voice')
        with_screen = (mode == 'voice_screen')
        audio_port = int(inv.get('audio_port') or DEFAULT_CALL_AUDIO_PORT)
        video_port = int(inv.get('video_port') or DEFAULT_CALL_VIDEO_PORT)
        if self._launch_call_session(host, audio_port, video_port, with_screen=with_screen):
            who = str(inv.get('sender') or host)
            self.status.setText(f'Joined call from {who} ({mode})')
            self._append_system(f'Joined call from {who} ({mode}).')
        else:
            self.status.setText('Failed to join call session.')

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
                continue
            if kind == 'voice_message':
                _kind, sender, host, port, mime, duration, blob = evt
                if port and port > 0:
                    self._upsert_peer(sender, host, int(port), 'LAN')
                item = self._save_voice_blob(sender, mime, duration, blob)
                if item is not None:
                    self._append_line(
                        f'[{time.strftime("%H:%M:%S")}] {sender} [VOICE {float(duration):.0f}s] '
                        f'(open Voice Inbox to play)'
                    )
                    self._push_recent_message(f'{sender} [VOICE]', f'Voice message ({float(duration):.0f}s)')
                    self.status.setText(f'New voice message from {sender}')
                continue
            if kind == 'call_invite':
                _kind, sender, host, port, mode, audio_port, video_port, note = evt
                if port and port > 0:
                    self._upsert_peer(sender, host, int(port), 'LAN')
                self.last_call_invite = {
                    'sender': str(sender or host),
                    'host': str(host or ''),
                    'mode': str(mode or 'voice'),
                    'audio_port': int(audio_port or DEFAULT_CALL_AUDIO_PORT),
                    'video_port': int(video_port or DEFAULT_CALL_VIDEO_PORT),
                    'note': str(note or ''),
                    'ts': int(time.time()),
                }
                extra = f" | {note}" if str(note or '').strip() else ''
                self._append_system(
                    f"Call invite from {sender} [{host}] mode={mode} "
                    f"(audio:{int(audio_port or DEFAULT_CALL_AUDIO_PORT)} video:{int(video_port or DEFAULT_CALL_VIDEO_PORT)}){extra}"
                )
                self.status.setText('Incoming call invite: use "Join Last Invite" action.')
                continue
            if kind == 'world_chat':
                _kind, sender, text = evt
                hhmm = time.strftime('%H:%M:%S')
                self._append_line(f'[{hhmm}] {sender} [WORLD]: {text}')
                self._push_recent_message(f'{sender} [WORLD]', text)
                continue
            if kind == 'world_status':
                _kind, enabled, room = evt
                self._update_world_toggle_button()
                if bool(enabled):
                    self.status.setText(f'World chat connected ({room})')
                else:
                    self.status.setText('World chat disconnected')
                self._refresh_world_peer()
                continue
            if kind == 'world_room':
                _kind, room = evt
                self.status.setText(f'World room: {room}')
                self._refresh_world_peer()
                continue

    def closeEvent(self, e):
        try:
            self.timer.stop()
        except Exception:
            pass
        self._save_world_settings()
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
set -euo pipefail
PORT=${1:-8000}
DIR=${2:-$HOME}
[ -d "$DIR" ] || { echo "Directory not found: $DIR"; exit 1; }
case "$PORT" in
  ''|*[!0-9]*) echo "Port must be numeric"; exit 1 ;;
esac
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not available"
  exit 1
fi
cd "$DIR"
exec python3 -m http.server "$PORT"
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
echo "=== XUI Gamepad Test ==="
echo
if [ -x "$HOME/.xui/bin/xui_controller_probe.sh" ]; then
    "$HOME/.xui/bin/xui_controller_probe.sh" || true
    echo
fi

if command -v jstest-gtk >/dev/null 2>&1; then
    echo "Launching jstest-gtk..."
    jstest-gtk &
    exit 0
fi

if command -v jstest >/dev/null 2>&1; then
    DEV=""
    for d in /dev/input/js*; do
        [ -e "$d" ] || continue
        DEV="$d"
        break
    done
    if [ -n "$DEV" ]; then
        echo "Launching jstest on $DEV"
        exec jstest "$DEV"
    fi
fi

if command -v evtest >/dev/null 2>&1; then
    echo "evtest is available."
    echo "Tip: run 'sudo evtest' to inspect raw Joy-Con/Xbox events."
    exit 0
fi

echo "No gamepad tester installed (jstest-gtk/jstest/evtest)."
exit 1
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
if [ -x "$HOME/.xui/bin/xui_install_fnae_deps.sh" ]; then
  "$HOME/.xui/bin/xui_install_fnae_deps.sh" || true
fi
BASH
        chmod +x "$BIN_DIR/xui_update_system.sh"

        # RetroArch installer
        cat > "$BIN_DIR/xui_install_retroarch.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
as_root(){
  if [ "$(id -u)" -eq 0 ]; then "$@"; return $?; fi
  if [ "${XUI_NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
    if command -v pkexec >/dev/null 2>&1; then pkexec "$@"; return $?; fi
    if command -v sudo >/dev/null 2>&1; then sudo -n "$@"; return $?; fi
  else
    if command -v sudo >/dev/null 2>&1; then sudo "$@"; return $?; fi
    if command -v pkexec >/dev/null 2>&1; then pkexec "$@"; return $?; fi
  fi
  echo "root privileges unavailable: $*" >&2
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
  if [ "${XUI_NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
    if command -v pkexec >/dev/null 2>&1; then pkexec "$@"; return $?; fi
    if command -v sudo >/dev/null 2>&1; then sudo -n "$@"; return $?; fi
  else
    if command -v sudo >/dev/null 2>&1; then sudo "$@"; return $?; fi
    if command -v pkexec >/dev/null 2>&1; then pkexec "$@"; return $?; fi
  fi
  echo "root privileges unavailable: $*" >&2
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
  if [ "${XUI_NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
    if command -v pkexec >/dev/null 2>&1; then pkexec "$@"; return $?; fi
    if command -v sudo >/dev/null 2>&1; then sudo -n "$@"; return $?; fi
  else
    if command -v sudo >/dev/null 2>&1; then sudo "$@"; return $?; fi
    if command -v pkexec >/dev/null 2>&1; then pkexec "$@"; return $?; fi
  fi
  echo "root privileges unavailable: $*" >&2
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
set -euo pipefail
OUT_DIR="$HOME/.xui/assets/records"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/rec-$(date +%Y%m%d-%H%M%S).mkv"
FPS=${1:-25}
case "$FPS" in
  ''|*[!0-9]*) echo "FPS must be numeric"; exit 1 ;;
esac
if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg not installed"; exit 1
fi
if ! command -v xdpyinfo >/dev/null 2>&1; then
    echo "xdpyinfo not installed"; exit 1
fi
DISPLAY_ID="${DISPLAY:-:0}"
SIZE="$(xdpyinfo 2>/dev/null | awk '/dimensions:/{print $2; exit}')"
[ -n "${SIZE:-}" ] || { echo "Could not determine display size"; exit 1; }
if command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then
    ffmpeg -video_size "$SIZE" -framerate "$FPS" -f x11grab -i "$DISPLAY_ID" -f pulse -i default "$OUT"
else
    ffmpeg -video_size "$SIZE" -framerate "$FPS" -f x11grab -i "$DISPLAY_ID" "$OUT"
fi
echo "$OUT"
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
set -euo pipefail

if command -v kodi >/dev/null 2>&1; then
  exec kodi "$@"
fi

if command -v kodi-standalone >/dev/null 2>&1; then
  exec kodi-standalone "$@"
fi

if command -v flatpak >/dev/null 2>&1; then
  if flatpak info tv.kodi.Kodi >/dev/null 2>&1; then
    exec flatpak run tv.kodi.Kodi "$@"
  fi
fi

if command -v snap >/dev/null 2>&1; then
  if snap list kodi >/dev/null 2>&1; then
    exec snap run kodi "$@"
  fi
fi

echo "Kodi is not installed."
echo "Install options:"
echo "  Ubuntu/Debian: sudo apt install kodi"
echo "  Flatpak:       flatpak install -y flathub tv.kodi.Kodi"
exit 1
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

set_cpu_default_max(){
    local cpu f max_file max_val
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        f="$cpu/cpufreq/scaling_max_freq"
        max_file="$cpu/cpufreq/cpuinfo_max_freq"
        [ -f "$f" ] || continue
        [ -f "$max_file" ] || continue
        max_val="$(cat "$max_file" 2>/dev/null || true)"
        [ -n "$max_val" ] || continue
        if [ -w "$f" ]; then
            echo "$max_val" > "$f" || true
        else
            sudo sh -c "echo $max_val > $f" 2>/dev/null || true
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
        set_cpu_default_max || true
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

        # Platform-aware power optimizer for handhelds/laptops (Linux active, future OS placeholders).
        cat > "$BIN_DIR/xui_power_optimize.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-auto}" # auto|battery|ac|balanced|performance
CONF="$HOME/.xui/data/power_platform_profile.json"
mkdir -p "$(dirname "$CONF")"

is_on_ac(){
  for a in /sys/class/power_supply/AC*/online /sys/class/power_supply/AC/online /sys/class/power_supply/*/online; do
    [ -f "$a" ] || continue
    case "$(cat "$a" 2>/dev/null || true)" in
      1) return 0 ;;
    esac
  done
  return 1
}

device_tag(){
  local m=""
  m="$(cat /proc/device-tree/model 2>/dev/null || true)"
  if [ -z "$m" ]; then
    m="$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || true) $(cat /sys/devices/virtual/dmi/id/board_name 2>/dev/null || true)"
  fi
  m="$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')"
  if echo "$m" | grep -Eq 'switch|tegra|l4t'; then echo "switch-l4t"; return; fi
  if echo "$m" | grep -Eq 'steam deck|neptune|jupiter'; then echo "steamdeck"; return; fi
  if echo "$m" | grep -Eq 'rog ally|aya|gpd|onexplayer|legion go'; then echo "pc-handheld"; return; fi
  echo "generic-linux"
}

set_governor(){
  local gov="$1"
  for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
    [ -f "$f" ] || continue
    if [ -w "$f" ]; then
      echo "$gov" > "$f" 2>/dev/null || true
    fi
  done
}

set_cpu_max(){
  local val="$1"
  [ -n "$val" ] || return 0
  for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_max_freq; do
    [ -f "$f" ] || continue
    if [ -w "$f" ]; then
      echo "$val" > "$f" 2>/dev/null || true
    fi
  done
}

apply_linux_profile(){
  local prof="$1" tag="$2"
  case "$prof" in
    battery)
      set_governor powersave || true
      case "$tag" in
        switch-l4t) set_cpu_max 1020000 || true ;;
        steamdeck|pc-handheld) set_cpu_max 1800000 || true ;;
        *) set_cpu_max 1400000 || true ;;
      esac
      "$HOME/.xui/bin/xui_battery_saver.sh" enable >/dev/null 2>&1 || true
      ;;
    ac|performance)
      set_governor schedutil || set_governor performance || true
      "$HOME/.xui/bin/xui_battery_saver.sh" disable >/dev/null 2>&1 || true
      ;;
    balanced|*)
      set_governor schedutil || true
      "$HOME/.xui/bin/xui_battery_saver.sh" disable >/dev/null 2>&1 || true
      ;;
  esac
}

tag="$(device_tag)"
profile="$MODE"
if [ "$MODE" = "auto" ]; then
  if is_on_ac; then profile="ac"; else profile="battery"; fi
fi

uname_s="$(uname -s 2>/dev/null || echo Linux)"
if [ "$uname_s" = "Linux" ]; then
  apply_linux_profile "$profile" "$tag"
fi

cat > "$CONF" <<JSON
{
  "platform_detected": "$tag",
  "os": "$uname_s",
  "profile_applied": "$profile",
  "future_targets": ["windows", "android9plus", "windows_handheld"]
}
JSON

echo "Power optimizer: $profile ($tag)"
BASH
        chmod +x "$BIN_DIR/xui_power_optimize.sh"

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

        cat > "$SYSTEMD_USER_DIR/xui-power-opt.service" <<UNIT
[Unit]
Description=XUI Power Optimizer
After=graphical-session.target

[Service]
Type=oneshot
ExecStart=%h/.xui/bin/xui_power_optimize.sh auto

[Install]
WantedBy=default.target
UNIT

}


configure_dashboard_passwordless_sudo(){
  local target_user target_home sudoers_file cmd1 cmd2 tmpf
  target_user="${SUDO_USER:-$USER}"
  target_home="$HOME"
  if [ -n "${SUDO_USER:-}" ]; then
    if command -v getent >/dev/null 2>&1; then
      local su_home
      su_home="$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)"
      if [ -n "${su_home:-}" ]; then
        target_home="$su_home"
      fi
    elif [ -d "/home/$SUDO_USER" ]; then
      target_home="/home/$SUDO_USER"
    fi
  fi
  cmd1="$target_home/.xui/bin/xui_startup_and_dashboard.sh"
  cmd2="$target_home/.xui/bin/xui_start.sh"
  sudoers_file="/etc/sudoers.d/xui-dashboard-${target_user}"
  tmpf="$(mktemp /tmp/xui-sudoers.XXXXXX)"
  printf '%s ALL=(root) NOPASSWD: %s, %s\n' "$target_user" "$cmd1" "$cmd2" > "$tmpf"

  if ! run_as_root install -m 0440 "$tmpf" "$sudoers_file"; then
    warn "Could not install sudoers rule for passwordless dashboard."
    rm -f "$tmpf"
    return 1
  fi

  if command -v visudo >/dev/null 2>&1; then
    if ! run_as_root visudo -cf "$sudoers_file" >/dev/null 2>&1; then
      warn "sudoers validation failed, removing $sudoers_file"
      run_as_root rm -f "$sudoers_file" || true
      rm -f "$tmpf"
      return 1
    fi
  fi

  rm -f "$tmpf"
  info "Configured passwordless sudo for dashboard launch ($target_user)."
  return 0
}


finish_setup(){
  info "Finalizing installation"
  run_user_systemctl(){
    local rc
    if command -v timeout >/dev/null 2>&1; then
      timeout "${XUI_SYSTEMCTL_TIMEOUT_SEC:-15}" systemctl --user "$@" >/dev/null 2>&1
      rc=$?
      if [ "$rc" -eq 124 ]; then
        warn "systemctl --user $* timed out after ${XUI_SYSTEMCTL_TIMEOUT_SEC:-15}s"
        return 1
      fi
      return "$rc"
    fi
    systemctl --user "$@" >/dev/null 2>&1
  }
  # make sure everything is executable
  chmod -R a+x "$BIN_DIR" || true
  chmod +x "$DASH_DIR/pyqt_dashboard_improved.py" || true
  chmod +x "$DASH_DIR/pyqt_dashboard.py" || true
  chmod +x "$BIN_DIR/xui_joy_listener.py" || true
  touch "$XUI_DIR/.xui_4_0xv_setup_done"
  configure_dashboard_passwordless_sudo || warn "Dashboard may ask for credentials until sudoers rule is applied."
  info "Configuring autostart for each login"
  mkdir -p "$AUTOSTART_DIR" "$SYSTEMD_USER_DIR" || true
  local openbox_file xprofile_file
  openbox_file="$HOME/.config/openbox/autostart"
  xprofile_file="$HOME/.xprofile"
  mkdir -p "$(dirname "$openbox_file")" || true
  touch "$openbox_file" "$xprofile_file" || true
  # Remove legacy duplicate autostart hooks (Openbox / xprofile).
  sed -i '/xui_startup_and_dashboard.sh/d' "$openbox_file" 2>/dev/null || true
  sed -i '/xui_startup_and_dashboard.sh/d' "$xprofile_file" 2>/dev/null || true
  info "Cleaned Openbox/Xprofile duplicate hooks."

  # Keep desktop autostart disabled when systemd user service is available.
  if [ -f "$AUTOSTART_DIR/xui-dashboard.desktop" ]; then
    sed -i 's/^Hidden=.*/Hidden=true/' "$AUTOSTART_DIR/xui-dashboard.desktop" 2>/dev/null || true
    sed -i 's/^X-GNOME-Autostart-enabled=.*/X-GNOME-Autostart-enabled=false/' "$AUTOSTART_DIR/xui-dashboard.desktop" 2>/dev/null || true
  fi
  if command -v systemctl >/dev/null 2>&1; then
    if run_user_systemctl daemon-reload; then
      run_user_systemctl enable --now xui-dashboard.service xui-joy.service || true
      run_user_systemctl enable --now xui-battery-monitor.service || true
      run_user_systemctl enable --now xui-power-opt.service || true
      info "Attempted to enable user services: xui-dashboard, xui-joy, xui-battery-monitor, xui-power-opt"
    else
      warn "systemctl --user daemon-reload failed; using desktop autostart only"
    fi
  fi
  if [ -x "$BIN_DIR/xui_install_fnae_deps.sh" ]; then
    if command -v timeout >/dev/null 2>&1; then
      XUI_NONINTERACTIVE=1 timeout "${XUI_FNAE_DEPS_TIMEOUT_SEC:-120}" "$BIN_DIR/xui_install_fnae_deps.sh" || true
    else
      XUI_NONINTERACTIVE=1 "$BIN_DIR/xui_install_fnae_deps.sh" || true
    fi
  fi
  info "Installation complete."
}

main(){
  parse_args "$@"
  if [ "${XUI_ONLY_REFRESH_CONTROLLERS:-0}" = "1" ]; then
    info "Refreshing controller integration only (Joy-Con/Xbox)"
    ensure_dirs
    write_joy_py
    write_systemd_and_autostart
    write_even_more_apps
    if command -v systemctl >/dev/null 2>&1; then
      systemctl --user daemon-reload >/dev/null 2>&1 || true
      systemctl --user restart xui-joy.service >/dev/null 2>&1 || true
    fi
    info "Controller tools refreshed. Run:"
    info "  ~/.xui/bin/xui_controller_probe.sh"
    info "  ~/.xui/bin/xui_controller_mappings.sh"
    info "  ~/.xui/bin/xui_controller_l4t_fix.sh"
    exit 0
  fi
  if [ "${XUI_ONLY_REFRESH_STORE:-0}" = "1" ]; then
    info "Refreshing store UI only (fast mode)"
    ensure_dirs
    write_extras
    info "Store UI refreshed at: $HOME/.xui/games/store.py"
    info "Now restart dashboard and open Store again."
    exit 0
  fi
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
  if [ "${XUI_SKIP_LAUNCH_PROMPT:-0}" = "1" ]; then
    info "Skipping launch prompt (XUI_SKIP_LAUNCH_PROMPT=1)"
  elif confirm "Do you want to launch the dashboard now?"; then
    "$BIN_DIR/xui_start.sh"
  fi
}

main "$@"
