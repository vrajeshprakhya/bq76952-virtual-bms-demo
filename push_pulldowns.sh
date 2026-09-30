#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"
rm -f kicad/build_fab_body.cir
git add -A
git commit -q -F - <<'EOF'
Gate pull-downs R8/R10: 10k -> 1M (found by the fab-netlist sim)

OP1 of the export-level simulation read 1001.98 mA for a commanded
1 A: the two 10k gate-source pull-downs, held at 10 V by the AFE's
gate drive, each bled 1 mA through the shunt -- a permanent +2 mA
current-measurement offset, and a load no real BQ769x0's uA-class
charge-pump gate driver could sustain.  OP4 corroborated (its delta
vs OP1 was exactly one pull-down's worth).  With 1M: 1000.02 mA
(residual 20 uA), body-diode case 1.00001 mV.  The OP1 assertion is
tightened to +-2 mA so a return to stiff pull-downs fails the loop.
prove_sim.sh added: diffs the kicad-cli export against what ngspice
consumed (two mechanical lines; all 50 component cards identical).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
git push -q
git log --oneline -1
git status --short | head -3
echo PUSHED
