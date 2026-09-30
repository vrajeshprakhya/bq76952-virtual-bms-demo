#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"
rm -f kicad/build_fab_body.cir
git add -A
git commit -q -F - <<'EOF'
Make the fab schematic itself SPICE-simulatable (verify stage 4)

Every non-passive on bms_6s_fab.kicad_sch now carries Sim.* fields
binding it to a behavioural subckt in kicad/bms_fab_models.lib, so
kicad-cli's SPICE export of the sheet is directly runnable.  The
testbench lives inside the connector models -- PACK6S (J1) is the 6S
stack + Rint, LOADBOX (J2) the commanded load obeying i = ILOAD*DSGON
-- and scenario knobs are global params driven with alterparam+reset.
run_fab_sim.sh (now stage 4 of verify_sch.sh) exports and runs four
asserted operating points: nominal (c1 = 3.688 V, 1002 mA), DSG open
(0 A, sag vanished), balancing (droop DERIVED from the sheet's own
100R filters: 16.0 mA, 0.4810 V vs 0.4810 analytic), and CHG-open
discharge through the body diode.

This resolves the 100R-vs-10R filter divergence as a documented
two-regime story (CROSSCHECK.md): BQ76930 + 100R = large-droop
regime, asserted here; the RNM's 40 mV = BQ76952-class small-droop
regime of the hand decks.  Bring-up fixes: ngspice auto-aliases GND
to node 0 (a GND-0 tie is a shorted source), reset wipes prior
plots' vectors (values captured to shell vars), and a hollow-PASS
guard: the PASS line must carry the measured numbers.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
git push -q
git log --oneline -1
git status --short | head -3
echo PUSHED
