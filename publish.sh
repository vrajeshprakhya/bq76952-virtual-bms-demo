#!/usr/bin/env bash
# One-shot: init the git repo, commit everything, create the GitHub
# repo under vrajeshprakhya and push.
set -eu
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"

REPO=bq76952-virtual-bms-demo

git init -q -b main
git config user.name "Vrajesh Prakhya"
git config user.email "vrajeshprakhya@gmail.com"
git add -A
git commit -q -F - <<'EOF'
Virtual 6S BMS co-verification demo + evidence package

SV-RNM board (6S pack, BQ76952-class AFE with register map and
protection engine), real C host firmware over pin-level open-drain
I2C, UVM-MS environment on xezim; SPICE netlists of the same circuit
simulated with ngspice; whitepaper and the full logs of both
simulators with a number-by-number crosscheck.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF

gh repo create "vrajeshprakhya/$REPO" --private --source . --push \
  --description "Virtual 6S BMS: SV-RNM board + BQ76952-class AFE model + real firmware over pin-level I2C, verified with UVM-MS on xezim; ngspice-simulated schematic and full evidence logs for the whitepaper"

git log --oneline -1
gh repo view "vrajeshprakhya/$REPO" --json url,visibility -q '.url + "  (" + .visibility + ")"'
