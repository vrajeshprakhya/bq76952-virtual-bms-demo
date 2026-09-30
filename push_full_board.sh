#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"
rm -f schematic/full_board_check.png
git add -A
git commit -q -F - <<'EOF'
Add the FULL board schematic: simulable netlist + drawn sheet

bms_full_board.cir extends the one-path deck to the complete board:
all 7 filtered cell-sense lines, per-cell balancing bleeders (the
40 mV read-droop is now DERIVED: 1.98 mA through 2 x 10 Ohm sense
lines = 39.7 mV, vs the RNM's 40 mV parameter), DSG+CHG FETs with
body diodes, charger stub, shunt kelvin with the EMI injection point,
I2C pull-ups with open-drain pulls on both ends (wired-AND shown in
transient), and the NTC divider.  bms_full_board.tex/.pdf is the
drawn schematic sheet, 1:1 with the netlist.  Logs in logs_ngspice/;
README and CROSSCHECK updated (incl. two fidelity notes: neighbour
+20 mV balancing artifact, kelvin-filter ripple attenuation).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
git push -q
git log --oneline -2
git status --short | head -3
echo PUSHED
