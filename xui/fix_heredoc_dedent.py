#!/usr/bin/env python3
from pathlib import Path
import re, textwrap, sys
p=Path('/home/smr/Descargas/xui/xui11.sh.fixed')
s=p.read_text(encoding='utf-8')
start_pat = r"cat > \"\$DASH_DIR/pyqt_dashboard_improved.py\" <<'XUI_HEREDOC_4'\n"
m = re.search(start_pat, s)
if not m:
    print('start not found')
    sys.exit(2)
start = m.end()
end_marker = '\nXUI_HEREDOC_4\n'
end = s.find(end_marker, start)
if end == -1:
    print('end not found')
    sys.exit(3)
block = s[start:end]
# We will dedent using textwrap.dedent repeatedly until no leading common indent
ded = textwrap.dedent(block)
# Also strip up to 4 leading spaces if still present at start of lines
lines = ded.splitlines()
# Find minimal indent for non-blank lines
import re
indents = [len(re.match(r'^(\s*)', ln).group(1)) for ln in lines if ln.strip()]
min_indent = min(indents) if indents else 0
# If min_indent>0, remove exactly that many spaces
if min_indent>0:
    lines2 = [(ln[min_indent:] if len(ln)>=min_indent else '') for ln in lines]
else:
    lines2 = lines
new_block = '\n'.join(lines2)
# Ensure it ends with a newline
if not new_block.endswith('\n'):
    new_block = new_block + '\n'
new_s = s[:start] + new_block + s[end:]
# Backup
bak = p.with_suffix('.fixed.bak')
bak.write_text(s, encoding='utf-8')
p.write_text(new_s, encoding='utf-8')
print('done, backup at', bak)
