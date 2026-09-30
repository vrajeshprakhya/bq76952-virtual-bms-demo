#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"
git add -A
git commit -q -F - <<'EOF'
Add schematic verification loop: netlist export + golden connectivity

The fab sheet uses net-label connectivity, so ERC alone proves nothing
dangles but not that labels join the intended pins.  verify_sch.sh now
runs after every schematic change: ERC (0 required), kicadxml + spice
netlist exports (committed artifacts), and check_netlist.py, which
compares KiCad's own exported netlist pin-for-pin against GOLDEN --
the written-out intended connectivity of all 43 functional nets
(exact-match) plus GND/+3V3/B6 (subset), and flags any stray net.
Current result: 43/43 nets match exactly.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
git push -q
git log --oneline -1
echo PUSHED
