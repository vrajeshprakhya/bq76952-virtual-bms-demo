#!/usr/bin/env bash
# v2 co-simulation: VIRTUAL-TIME QUANTUM COUPLING.  The emulated CPU's
# own virtual clock drives board time (compute costs time); the AFE's
# ALERT is a real NVIC interrupt.  Pass gate: the same cross-domain
# checker as v1.  Logs: ../logs_v2/{xezim.log, renode.log, uart.log}
set -eu
cd "$(dirname "$0")"
XEZIM=${XEZIM:-$HOME/xezim/target/release/xezim}
RENODE=${RENODE:-$HOME/renode-portable/renode}
# fault/drift knobs: FW_FAULT=, XZ_DEFS="-D FAULT_COFF" or
# "-D AFE_DRIFT_PPM=<n>", BR_FAULT_SDA_STUCK=1
FW_FAULT=${FW_FAULT:-}
XZ_DEFS=${XZ_DEFS:-}
BR_FAULT_SDA_STUCK=${BR_FAULT_SDA_STUCK:-0}
mkdir -p ../logs_v2 build

echo "== firmware (ARM, v2)${FW_FAULT:+  [FAULT_$FW_FAULT]} =="
make -s -C fw_arm fw_v2.elf FAULT="$FW_FAULT"

echo "== bridge2 DPI library =="
cc -shared -fPIC -O2 -Wall -I"$HOME/xezim/include" \
   bridge/xezim_bridge2.c -o build/bridge2.so

BRTAG=""; [ "$BR_FAULT_SDA_STUCK" = "1" ] && BRTAG="  [BR_FAULT_SDA_STUCK]"
echo "== xezim (background, waits for Renode)${XZ_DEFS:+  [$XZ_DEFS]}$BRTAG =="
rm -f uart_v2.log
BR_FAULT_SDA_STUCK="$BR_FAULT_SDA_STUCK" \
"$XEZIM" --simulate --sv2017 --error-exit \
  $XZ_DEFS \
  -f xezim_v2.f -s top_v2 \
  --dpi-lib build/bridge2.so \
  --max-time 400ms \
  > ../logs_v2/xezim.log 2>&1 &
XPID=$!
sleep 1

echo "== Renode (console) =="
"$RENODE" --console --disable-xwt cosim_v2.resc \
  > ../logs_v2/renode.log 2>&1 || true

wait $XPID || true
cp -f uart_v2.log ../logs_v2/uart.log 2>/dev/null || true

echo "---- firmware UART ----"
cat ../logs_v2/uart.log
echo "---- board events (xezim) ----"
grep -E 'scenario|board|renode_bridge' ../logs_v2/xezim.log || true
echo "---- cross-domain check ----"
python3 check_cosim.py ../logs_v2/uart.log ../logs_v2/xezim.log
echo "COSIM-V2: PASS"
