#!/usr/bin/env bash
# Simulate the fab schematic ITSELF: export the SPICE netlist from
# bms_6s_fab.kicad_sch with kicad-cli, then run the assertion
# testbench (bms_fab_tb.cir) on that export with ngspice.
# Log: ../logs_ngspice/fab_sim.log
set -eu
cd "$(dirname "$0")"

CLI=$(command -v kicad-cli || true)
if [ -z "$CLI" ]; then
  W="/mnt/c/Users/vraje/AppData/Local/Programs/KiCad/10.0/bin/kicad-cli.exe"
  [ -x "$W" ] && CLI="$W"
fi
[ -z "$CLI" ] && { echo "kicad-cli not found"; exit 2; }
NG=${NG:-$HOME/ngspice-install/bin/ngspice}

"$CLI" sch export netlist --format spice --output bms_6s_fab.cir bms_6s_fab.kicad_sch

# body for the testbench: no .end, models include localised
grep -v '^\.end' bms_6s_fab.cir \
  | sed 's|^\.include .*bms_fab_models.*|* (models included by the testbench)|' \
  > build_fab_body.cir

"$NG" -b bms_fab_tb.cir > ../logs_ngspice/fab_sim.log 2>&1 || true
grep -E 'OP[1-4]|FAIL|FAB-SIM' ../logs_ngspice/fab_sim.log
# PASS must carry a real measured c1 (guards against hollow passes)
grep -q 'FAB-SIM: PASS c1=3.68' ../logs_ngspice/fab_sim.log
