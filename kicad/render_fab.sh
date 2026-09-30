#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")"
[ -f erc.rpt ] && mv -f erc.rpt bms_6s_fab_erc.rpt
python3 - <<'EOF'
import fitz
d = fitz.open("bms_6s_fab.pdf")
d[0].get_pixmap(dpi=72).save("fab_check.png")
print("rendered", d[0].rect)
EOF
