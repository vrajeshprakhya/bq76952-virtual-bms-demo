#!/usr/bin/env bash
set -u
cd "$(dirname "$0")"
echo "--- diff: kicad-cli export vs what ngspice included ---"
diff bms_6s_fab.cir build_fab_body.cir
echo "DIFF-RC=$? (1 = differences shown above only)"
echo "--- component-card counts (R/C/X), export vs body ---"
grep -cE '^(R|C|X)' bms_6s_fab.cir
grep -cE '^(R|C|X)' build_fab_body.cir
echo "--- timestamps ---"
ls -l --time-style=+%H:%M:%S bms_6s_fab.cir build_fab_body.cir \
  ../logs_ngspice/fab_sim.log
