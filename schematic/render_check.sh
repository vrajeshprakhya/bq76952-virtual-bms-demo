#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")"
python3 - <<'EOF'
import fitz
d = fitz.open("bms_full_board.pdf")
d[0].get_pixmap(dpi=95).save("full_board_check.png")
print("rendered", d[0].rect)
EOF
