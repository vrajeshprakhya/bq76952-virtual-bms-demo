#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"
rm -f kicad/fab_check.png
git add -A
git commit -q -F - <<'EOF'
Rewire the fab schematic: drawn point-to-point wires, not label glue

Rev B of kicad/bms_6s_fab.kicad_sch: every connection is now drawn
copper -- 186 orthogonal wire segments with 44 explicit junction dots.
Each functional net keeps ONE small name tag riding on its wire, which
is what keeps check_netlist.py's golden table addressable by name.
Layout: fan-out corridors beside each IC (one vertical slot per net),
cell rows spread to 10.16 mm pitch for the differential input caps,
gate networks fed from a left bypass row so series resistors sit
in-line.

The verification loop earned its keep during the rewire: it caught a
real SRP/SRN kelvin polarity swap (R5 wired to the battery-side sense
pin; would have inverted the current reading), two shorted gate feeds
from resistors placed on top of their feed wires, and net-name tags
sitting exactly on wire crossings (which would have merged nets).
Final state: ERC 0 violations, 43/43 golden nets pin-for-pin.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
git push -q
git log --oneline -1
echo PUSHED
