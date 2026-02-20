#!/usr/bin/env python3
from pathlib import Path
import re, sys
src = Path(__file__).parent / 'xui11.sh'
if not src.exists():
    print('source xui11.sh not found', src); sys.exit(2)
text = src.read_text(encoding='utf-8')
start_pat = "cat > \"$DASH_DIR/pyqt_dashboard_improved.py\" <<'PY'\n"
m = re.search(start_pat, text)
if not m:
    print('start pattern not found'); sys.exit(3)
start = m.end()
end_marker = '\nPY\n'
end = text.find(end_marker, start)
if end == -1:
    print('end marker not found'); sys.exit(4)
block = text[start:end]
# block should already be correct; strip possible leading indentation caused by file context
import textwrap
ded = textwrap.dedent(block)
# write to workspace copy
out_ws = Path(__file__).parent / 'pyqt_dashboard_from_original.py'
out_ws.write_text(ded, encoding='utf-8')
print('WROTE', out_ws)
# write to target ~/.xui/dashboard/pyqt_dashboard_improved.py
home_target = Path.home() / '.xui' / 'dashboard'
home_target.mkdir(parents=True, exist_ok=True)
target = home_target / 'pyqt_dashboard_improved.py'
target.write_text(ded, encoding='utf-8')
print('WROTE TARGET', target)
# set executable bit
try:
    import os
    os.chmod(target, 0o755)
except Exception:
    pass
print('done')
