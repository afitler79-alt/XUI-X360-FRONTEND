#!/usr/bin/env python3
"""Extract embedded heredoc XUI_HEREDOC_4 from xui11.sh.fixed and write a dedented python file.
Preserves all lines; only strips a common leading indentation so Python indentation is correct.
"""
import re
from pathlib import Path
sfile = Path(__file__).parent / 'xui11.sh.fixed'
out = Path(__file__).parent / 'pyqt_dashboard_improved_fixed.py'
text = sfile.read_text(encoding='utf-8')
# Find the heredoc start marker
m = re.search(r"cat > \"\$DASH_DIR/pyqt_dashboard_improved.py\" <<'XUI_HEREDOC_4'\n", text)
if not m:
    print('HEREDOC_START_NOT_FOUND')
    raise SystemExit(2)
start = m.end()
end_marker = '\nXUI_HEREDOC_4\n'
end = text.find(end_marker, start)
if end == -1:
    print('HEREDOC_END_NOT_FOUND')
    raise SystemExit(3)
block = text[start:end]
# Remove a common leading indentation (detect minimal indent >0 across non-blank lines)
lines = block.splitlines()
# compute common leading spaces across non-empty lines
import itertools
indents = [len(re.match(r"^(\s*)", ln).group(1)) for ln in lines if ln.strip()]
min_indent = min(indents) if indents else 0
if min_indent > 0:
    dedented = '\n'.join([ln[min_indent:] if len(ln) >= min_indent else '' for ln in lines])
else:
    dedented = '\n'.join(lines)
# Trim possible accidental leading/trailing blank line
if dedented.startswith('\n'):
    dedented = dedented.lstrip('\n')
# Write out
out.write_text(dedented, encoding='utf-8')
print('WROTE', out)
print('LINES', len(dedented.splitlines()))
