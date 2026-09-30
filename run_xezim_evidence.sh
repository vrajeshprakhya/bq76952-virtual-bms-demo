#!/usr/bin/env bash
# Run the UVM-MS bench from the evidence copy of the design and keep
# every log beside it.  Produces:
#   logs_xezim/smoke.log    one nominal operating point
#   logs_xezim/regress.log  the 13-scenario regression (seed 1)
#   logs_xezim/xezim_cov.json  functional coverage of the regress run
set -eu
E=$(cd "$(dirname "$0")" && pwd)
cd "$E/design"

echo "== smoke =="
TEST=bq_smoke_test ./run.sh > "$E/logs_xezim/smoke_console.txt" 2>&1
cp build/run.log "$E/logs_xezim/smoke.log"

echo "== regress =="
./run.sh > "$E/logs_xezim/regress_console.txt" 2>&1
cp build/run.log "$E/logs_xezim/regress.log"
cp xezim_cov.json "$E/logs_xezim/xezim_cov.json" 2>/dev/null || true

grep -F "TEST-VERDICT" "$E/logs_xezim/smoke.log" "$E/logs_xezim/regress.log"
echo "XEZIM-EVIDENCE-DONE"
