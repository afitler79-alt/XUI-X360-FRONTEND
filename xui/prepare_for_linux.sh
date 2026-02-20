#!/usr/bin/env bash
set -euo pipefail

echo "Preparing repository scripts for Linux (normalize line endings, set executables)"

SCRIPT_FILES=(xui11.sh xui11.sh.fixed xui11.sh.fixed.bak)
for f in "${SCRIPT_FILES[@]}"; do
  if [ -f "$f" ]; then
    echo "Processing $f"
    # Remove CRLF if present
    sed -i 's/\r$//' "$f" || true
    chmod +x "$f" || true
  fi
done

echo "Done. To run installer on target system:"
echo "  ./xui11.sh          # or ./xui11.sh.fixed"
echo "For non-interactive auto-install (tools), run:"
echo "  ./xui11.sh --yes-install"

exit 0
