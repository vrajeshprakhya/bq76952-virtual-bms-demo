#!/usr/bin/env bash
# Crop the A2 fabrication sheet to its drawn content (plus a small
# pad) so the whitepaper's appendix figure uses the page for circuit,
# not margin.  Design extents ~(0..235, 8..242) mm + centring offset
# (165.1, 81.28).
set -eu
cd "$(dirname "$0")"
cp -f "$HOME/bq_vboard_evidence/kicad/bms_6s_fab.pdf" board_schematic_full.pdf
python3 - <<'EOF'
import fitz
s = 2.8346
d = fitz.open("board_schematic_full.pdf")
p = d[0]
x0, y0 = (0 + 165.1 - 6) * s, (8 + 81.28 - 6) * s
x1, y1 = (235 + 165.1 + 6) * s, (242 + 81.28 + 6) * s
p.set_cropbox(fitz.Rect(x0, y0, x1, y1))
d.save("board_schematic.pdf")
print("cropped to", p.cropbox)
EOF
rm -f board_schematic_full.pdf
