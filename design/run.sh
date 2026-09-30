#!/usr/bin/env bash
#=======================================================================
# run.sh -- build the firmware DPI library and run the UVM-MS bench.
#
#   ./run.sh                        # regress test, seed 1
#   TEST=bq_smoke_test ./run.sh     # smoke only
#   SEED=7 ./run.sh +n_corners=8    # more corners, other seed
#   WAVES=1 ./run.sh                # also dump build/wave.fst
#
# Env overrides: XEZIM (binary), XEZIM_INC (headers), UVM_SRC.
# Note: xezim stdout is block-buffered through the tee pipe -- a quiet
# build/run.log does NOT mean a hung run (check pgrep xezim CPU).
#=======================================================================
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

XEZIM=${XEZIM:-$HOME/xezim/target/release/xezim}
XEZIM_INC=${XEZIM_INC:-$HOME/xezim/include}
UVM_SRC=${UVM_SRC:-$HOME/iverilog-unified/uvm-core/src}
TEST=${TEST:-bq_regress_test}
SEED=${SEED:-1}

mkdir -p build

echo "== firmware DPI library =="
cc -shared -fPIC -O2 -Wall -I"$XEZIM_INC" fw/firmware.c -o build/fw.so
echo "   ok"

WAVE_ARGS=()
[ -n "${WAVES:-}" ] && WAVE_ARGS=(--fst build/wave.fst --fst-scope top.u_board)

echo "== xezim: $TEST (seed $SEED) =="
"$XEZIM" --simulate --sv2017 --error-exit \
  -D UVM_NO_DPI -D UVM_REPORT_DISABLE_FILE_LINE \
  +incdir+"$UVM_SRC" "$UVM_SRC/uvm_pkg.sv" \
  +incdir+fw +incdir+tb \
  --dpi-lib build/fw.so \
  -f compile.f -s top \
  --max-time 800ms \
  "${WAVE_ARGS[@]}" \
  +UVM_TESTNAME="$TEST" +seed="$SEED" "$@" 2>&1 \
  | tee build/run.log \
  | grep -vE '^\[(PROF|FUSE|COV|EVENT|PHASE)'

echo
if grep -q "TEST-VERDICT: PASS" build/run.log; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL (see build/run.log)"
  exit 1
fi
