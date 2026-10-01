#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")"
python3 - <<'EOF'
import fitz
d = fitz.open("bms_6s_fab.pdf")
p = d[0]
s = 2.8346  # pt per mm on this A2 sheet
# RS1 sits at design (152.4, 205.74) + centring offset (165.1, 81.28)
cx, cy = (152.4 + 165.1) * s, (205.74 + 81.28) * s
clip = fitz.Rect(cx - 55 * s, cy - 42 * s, cx + 62 * s, cy + 40 * s)
p.get_pixmap(dpi=160, clip=clip).save("rs1_zoom.png")
print("saved rs1_zoom.png", clip)
EOF
