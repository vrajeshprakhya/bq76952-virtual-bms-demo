#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")"
KCLI="/mnt/c/Users/vraje/AppData/Local/Programs/KiCad/10.0/bin/kicad-cli.exe"
command -v kicad-cli >/dev/null 2>&1 && KCLI=kicad-cli
"$KCLI" sch export pdf --output bms_6s_fab.pdf bms_6s_fab.kicad_sch
python3 - <<'EOF'
import fitz
d = fitz.open("bms_6s_fab.pdf")
p = d[0]
s = 2.8346  # pt per mm on this A2 sheet
# J3/J4 region: design x 75..135, y 165..218, + centring offset (165.1, 81.28)
x0, y0 = (75 + 165.1) * s, (165 + 81.28) * s
x1, y1 = (135 + 165.1) * s, (218 + 81.28) * s
p.get_pixmap(dpi=160, clip=fitz.Rect(x0, y0, x1, y1)).save("j4_zoom.png")
print("saved j4_zoom.png")
EOF
