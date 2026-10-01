#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"
rm -f kicad/build_fab_body.cir
git add -A
git commit -q -F - <<'EOF'
Add .op sheet directive so the GUI simulator is one-click

The schematic now carries a ".op" SPICE directive as sheet text:
Inspect -> Simulator -> Run in eeschema reproduces the nominal
operating point of the batch suite (cell taps 3.688 V, SRP ~1 mV at
1 A) using the same Sim.* bindings, models library and in-connector
testbench.  run_fab_sim.sh strips the directive from the batch body
(its control section runs its own four analyses).  All four verify
stages re-run green.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
git push -q
git log --oneline -1
echo PUSHED
