#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"
rm -f kicad/build_fab_body.cir
git add -A
git commit -q -F - <<'EOF'
Add AC6: kelvin-filter frequency sweep to the fab-netlist suite

Stimulus is a 0 V series source inside the SHUNT_1M model carrying
AC 1 -- by SPICE semantics the AC magnitude exists only for .ac, so
all five existing analyses are untouched (re-run bit-identical).
Transfer read differentially at SRP/SRN: passband gain 0.999999,
corner 7957.74 Hz vs 7957.75 analytic (1/(2*pi*200R*100n)), 20 kHz
gain 0.36976 (the number behind the full-board EMI attenuation
story), 500 kHz rolloff 0.01592 vs 0.01592 first-order prediction.
Response committed as fab_kelvin_ac.dat; fc rides the PASS line and
the runner's hollow-pass grep now requires it.  (First cut measured
the rolloff AT the sweep endpoint, which FIND cannot interpolate and
silently skipped -- moved to 500 kHz inside the sweep.)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
git push -q
rm -f push_ac.sh
git log --oneline -1
git status --short | head -3
echo DONE
