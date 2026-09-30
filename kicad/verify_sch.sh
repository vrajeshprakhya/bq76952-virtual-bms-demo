#!/usr/bin/env bash
# The schematic verification loop (run after EVERY schematic change):
#   1. kicad-cli ERC                    -> 0 violations required
#   2. export kicadxml + spice netlists -> committed artifacts
#   3. check_netlist.py                 -> exported connectivity must
#                                          match GOLDEN pin-for-pin
# Finds kicad-cli on PATH, or the per-user Windows install via /mnt/c.
set -eu
cd "$(dirname "$0")"

CLI=$(command -v kicad-cli || true)
if [ -z "$CLI" ]; then
  W="/mnt/c/Users/vraje/AppData/Local/Programs/KiCad/10.0/bin/kicad-cli.exe"
  [ -x "$W" ] && CLI="$W"
fi
[ -z "$CLI" ] && { echo "kicad-cli not found"; exit 2; }

"$CLI" sch erc --exit-code-violations --output erc.rpt bms_6s_fab.kicad_sch
mv -f erc.rpt bms_6s_fab_erc.rpt
echo "ERC: 0 violations"

"$CLI" sch export netlist --format kicadxml --output bms_6s_fab.xml bms_6s_fab.kicad_sch
"$CLI" sch export netlist --format spice    --output bms_6s_fab.cir bms_6s_fab.kicad_sch

python3 check_netlist.py
