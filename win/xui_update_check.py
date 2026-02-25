#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = os.environ.get("XUI_UPDATE_REPO", "afitler79-alt/XUI-X360-FRONTEND").strip() or "afitler79-alt/XUI-X360-FRONTEND"
XUI_HOME = Path.home() / ".xui"
DATA_HOME = XUI_HOME / "data"
STATE_FILE = DATA_HOME / "update_state.json"
CHANNEL_FILE = DATA_HOME / "update_channel.json"
SRC = Path(os.environ.get("XUI_SOURCE_DIR", str(XUI_HOME / "src" / "XUI-X360-FRONTEND"))).expanduser()
INSTALLER_NAME = os.environ.get("XUI_UPDATE_INSTALLER", "win/install_xui_windows.ps1").strip() or "win/install_xui_windows.ps1"
DEFAULT_BRANCH = os.environ.get("XUI_DEFAULT_UPDATE_BRANCH", "windows").strip() or "windows"


def ensure_data_home() -> None:
    DATA_HOME.mkdir(parents=True, exist_ok=True)


def read_state_commit() -> str:
    if not STATE_FILE.exists():
        return ""
    try:
        data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except Exception:
        return ""
    return str(data.get("installed_commit", "") or "").strip()


def read_channel_branch() -> str:
    if not CHANNEL_FILE.exists():
        return ""
    try:
        data = json.loads(CHANNEL_FILE.read_text(encoding="utf-8"))
    except Exception:
        return ""
    return str(data.get("branch", "") or "").strip()


def resolve_branch() -> str:
    env_branch = str(os.environ.get("XUI_UPDATE_BRANCH", "") or "").strip()
    if env_branch:
        return env_branch
    file_branch = read_channel_branch()
    if file_branch:
        return file_branch
    return DEFAULT_BRANCH


TARGET_BRANCH = resolve_branch()


def write_state(commit: str, branch: str, remote_date: str, src: Path) -> None:
    ensure_data_home()
    payload = {
        "installed_commit": str(commit or ""),
        "branch": str(branch or ""),
        "remote_date": str(remote_date or ""),
        "installed_at_epoch": int(time.time()),
        "source_dir": str(src),
        "version": 2,
    }
    STATE_FILE.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
    print("state-updated")


def fetch_json(url: str, timeout: int = 12):
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "xui-update-checker-win",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8", errors="ignore")
    return json.loads(raw)


def remote_meta():
    try:
        branch = TARGET_BRANCH
        commit = fetch_json(f"https://api.github.com/repos/{REPO}/commits/{branch}")
        sha = str(commit.get("sha", "") or "").strip()
        date = str((((commit.get("commit") or {}).get("committer") or {}).get("date")) or "")
        html = str(commit.get("html_url", "") or "")
        if not sha:
            return {"ok": False, "error": "missing-remote-sha", "branch": branch}
        return {
            "ok": True,
            "branch": branch,
            "sha": sha,
            "date": date,
            "url": html,
        }
    except Exception as exc:
        return {"ok": False, "error": str(exc), "branch": TARGET_BRANCH}


def emit_json(checked: bool, required: bool, reason: str, branch: str, local_commit: str, remote_commit: str, remote_date: str, remote_url: str) -> None:
    obj = {
        "checked": bool(checked),
        "mandatory": True,
        "update_required": bool(required),
        "reason": str(reason or ""),
        "repo": REPO,
        "branch": str(branch or ""),
        "local_commit": str(local_commit or ""),
        "remote_commit": str(remote_commit or ""),
        "remote_date": str(remote_date or ""),
        "remote_url": str(remote_url or ""),
    }
    print(json.dumps(obj, ensure_ascii=False))


def compute_status(json_out: bool = False) -> int:
    local_commit = read_state_commit()
    if not local_commit and (SRC / ".git").exists() and shutil.which("git"):
        try:
            local_commit = subprocess.check_output(
                ["git", "-C", str(SRC), "rev-parse", "HEAD"],
                stderr=subprocess.DEVNULL,
                text=True,
            ).strip()
        except Exception:
            local_commit = ""

    meta = remote_meta()
    if not meta.get("ok"):
        checked = False
        required = False
        reason = f"remote-unavailable:{meta.get('error', 'unknown')}"
        branch = str(meta.get("branch") or TARGET_BRANCH)
        remote_commit = ""
        remote_date = ""
        remote_url = ""
    else:
        checked = True
        branch = str(meta.get("branch") or TARGET_BRANCH)
        remote_commit = str(meta.get("sha") or "")
        remote_date = str(meta.get("date") or "")
        remote_url = str(meta.get("url") or "")
        if not local_commit:
            required = True
            reason = "missing-local-version"
        elif local_commit != remote_commit:
            required = True
            reason = "outdated"
        else:
            required = False
            reason = "up-to-date"

    if json_out:
        emit_json(checked, required, reason, branch, local_commit, remote_commit, remote_date, remote_url)
    else:
        print(f"Repo: {REPO}")
        print(f"Branch: {branch}")
        print(f"Checked: {'yes' if checked else 'no'}")
        print("Mandatory: yes")
        print(f"Local commit: {local_commit or '<none>'}")
        print(f"Remote commit: {remote_commit or '<unknown>'}")
        if remote_date:
            print(f"Remote date: {remote_date}")
        if remote_url:
            print(f"Remote URL: {remote_url}")
        print(f"Update required: {'yes' if required else 'no'}")
        print(f"Reason: {reason}")

    return 10 if required else 0


def run_stream(cmd, cwd=None) -> int:
    proc = subprocess.Popen(
        cmd,
        cwd=str(cwd) if cwd else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    assert proc.stdout is not None
    for line in proc.stdout:
        print(line.rstrip("\n"))
    return int(proc.wait())


def find_installer() -> Path:
    candidates = [
        INSTALLER_NAME,
        "win/install_xui_windows.ps1",
        "install_xui_windows.ps1",
        "win/install_xui_windows.bat",
        "install_xui_windows.bat",
    ]
    for item in candidates:
        p = Path(item)
        if not p.is_absolute():
            p = SRC / p
        if p.exists() and p.is_file():
            return p
    raise FileNotFoundError(f"Installer not found in repo: {SRC}")


def apply_update() -> int:
    git = shutil.which("git")
    if not git:
        print("git is required for apply mode")
        return 1

    meta = remote_meta()
    if not meta.get("ok"):
        print(f"Cannot reach GitHub metadata: {meta.get('error', 'unknown')}")
        return 1
    branch = str(meta.get("branch") or TARGET_BRANCH)
    remote_commit = str(meta.get("sha") or "")
    remote_date = str(meta.get("date") or "")

    SRC.parent.mkdir(parents=True, exist_ok=True)
    if not (SRC / ".git").exists():
        print("step=git-clone")
        rc = run_stream([git, "clone", f"https://github.com/{REPO}.git", str(SRC)])
        if rc != 0:
            return rc

    print("step=git-fetch")
    rc = run_stream([git, "-C", str(SRC), "fetch", "--all", "--prune"])
    if rc != 0:
        return rc
    rc = run_stream([git, "-C", str(SRC), "checkout", "-B", branch, f"origin/{branch}"])
    if rc != 0:
        return rc
    rc = run_stream([git, "-C", str(SRC), "reset", "--hard", f"origin/{branch}"])
    if rc != 0:
        return rc
    run_stream([git, "-C", str(SRC), "clean", "-fd"])

    installer = find_installer()
    print("step=installer-start")
    if installer.suffix.lower() == ".ps1":
        ps = shutil.which("pwsh") or shutil.which("powershell")
        if not ps:
            print("PowerShell is required to run Windows installer")
            return 1
        cmd = [
            ps,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(installer),
            "-SourceRoot",
            str(SRC),
            "-SkipPip",
        ]
    elif installer.suffix.lower() in (".bat", ".cmd"):
        cmd = ["cmd.exe", "/c", str(installer)]
    else:
        cmd = [str(installer)]
    rc = run_stream(cmd, cwd=SRC)
    print("step=installer-done")
    if rc != 0:
        print(f"Installer failed with code {rc}")
        return rc

    installed_commit = ""
    try:
        installed_commit = subprocess.check_output(
            [git, "-C", str(SRC), "rev-parse", "HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except Exception:
        installed_commit = remote_commit

    try:
        write_state(installed_commit, branch, remote_date, SRC)
        print("step=state-written")
    except Exception:
        print("warning=state-write-failed")

    print("update-applied")
    print(f"installed_commit={installed_commit}")
    return 0


def pull_only() -> int:
    git = shutil.which("git")
    if not git:
        print("git is required for pull mode")
        return 1
    if not (SRC / ".git").exists():
        print(f"No git repo at {SRC}")
        return 1
    rc = run_stream([git, "-C", str(SRC), "fetch", "--all", "--prune"])
    if rc != 0:
        return rc
    return run_stream([git, "-C", str(SRC), "checkout", "-B", TARGET_BRANCH, f"origin/{TARGET_BRANCH}"])


def release_info() -> int:
    try:
        info = fetch_json(f"https://api.github.com/repos/{REPO}/releases/latest")
        print("Latest release:", str(info.get("tag_name") or "unknown"))
        return 0
    except Exception as exc:
        print("Could not query latest release:", exc)
        return 1


def mark_current() -> int:
    git = shutil.which("git")
    if not git:
        print("git is required for mark mode")
        return 1
    if not (SRC / ".git").exists():
        print(f"No git repo at {SRC}")
        return 1
    commit = subprocess.check_output([git, "-C", str(SRC), "rev-parse", "HEAD"], text=True).strip()
    branch = subprocess.check_output([git, "-C", str(SRC), "rev-parse", "--abbrev-ref", "HEAD"], text=True).strip()
    write_state(commit, branch, "", SRC)
    print(f"marked-installed={commit}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("mode", nargs="?", default="status")
    parser.add_argument("--json", action="store_true", dest="json_out")
    args, _extra = parser.parse_known_args()
    ensure_data_home()
    mode = str(args.mode or "status").strip().lower()
    if mode in ("status", "mandatory"):
        return compute_status(json_out=bool(args.json_out))
    if mode == "pull":
        return pull_only()
    if mode == "apply":
        return apply_update()
    if mode == "release":
        return release_info()
    if mode == "mark":
        return mark_current()
    print("Usage: xui_update_check.py {status|mandatory|pull|apply|release|mark} [--json]")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
