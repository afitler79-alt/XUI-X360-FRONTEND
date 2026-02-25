#!/usr/bin/env python3
import argparse
import json
import re
import sys
from pathlib import Path

TARGETS = [
    ("$DASH_DIR/pyqt_dashboard_improved.py", "pyqt_dashboard_improved.py", True),
    ("$BIN_DIR/xui_webhub.py", "xui_webhub.py", True),
    ("$BIN_DIR/xui_social_chat.py", "xui_social_chat.py", True),
    ("$GAMES_DIR/store.py", "xui_store_modern.py", True),
    ("$BIN_DIR/xui_global_guide.py", "xui_global_guide.py", True),
    ("$BIN_DIR/xui_first_setup.py", "xui_first_setup.py", False),
    ("$BIN_DIR/xui_game_lib.py", "xui_game_lib.py", False),
    ("$BIN_DIR/xui_web_api.py", "xui_web_api.py", False),
]


def extract_last_heredoc(src_text: str, target_path: str):
    pattern = re.compile(
        r'cat > "' + re.escape(target_path) + r'" <<\'([^\']+)\'\n',
        re.MULTILINE,
    )
    matches = list(pattern.finditer(src_text))
    if not matches:
        return None
    m = matches[-1]
    marker = m.group(1)
    start = m.end()
    end_token = f"\n{marker}\n"
    end = src_text.find(end_token, start)
    if end < 0:
        raise RuntimeError(f"Heredoc marker not closed for {target_path} ({marker})")
    payload = src_text[start:end]
    if payload and not payload.endswith("\n"):
        payload += "\n"
    return payload


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract Windows payload from xui11.sh.fixed.sh")
    ap.add_argument("--source", required=True, help="Path to xui11.sh.fixed.sh")
    ap.add_argument("--out", required=True, help="Output directory")
    args = ap.parse_args()

    src = Path(args.source).expanduser().resolve()
    out = Path(args.out).expanduser().resolve()
    if not src.exists():
        print(f"[ERROR] source not found: {src}", file=sys.stderr)
        return 2
    out.mkdir(parents=True, exist_ok=True)

    text = src.read_text(encoding="utf-8", errors="replace")
    extracted = {}
    missing_required = []
    for bash_target, out_name, required in TARGETS:
        block = extract_last_heredoc(text, bash_target)
        if block is None:
            if required:
                missing_required.append(bash_target)
            continue
        dst = out / out_name
        dst.write_text(block, encoding="utf-8")
        extracted[out_name] = {
            "source_target": bash_target,
            "size": len(block),
            "lines": block.count("\n"),
        }
        print(f"[OK] extracted {out_name}")

    if missing_required:
        print("[ERROR] required targets were not found:", file=sys.stderr)
        for item in missing_required:
            print(f" - {item}", file=sys.stderr)
        return 3

    manifest = {
        "source": str(src),
        "files": extracted,
        "count": len(extracted),
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"[OK] manifest: {out / 'manifest.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
