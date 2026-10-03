#!/usr/bin/env bash
# v2 co-simulation: VIRTUAL-TIME QUANTUM COUPLING.  The emulated CPU's
# own virtual clock drives board time (compute costs time); the AFE's
# ALERT is a real NVIC interrupt.  Pass gate: the same cross-domain
# checker as v1.  Logs: ../logs_v2/{xezim.log, renode.log, uart.log}
set -eu
cd "$(dirname "$0")"
XEZIM=${XEZIM:-$HOME/xezim/target/release/xezim}
RENODE=${RENODE:-$HOME/renode-portable/renode}
mkdir -p ../logs_v2 build

echo "== firmware (ARM, v2) =="
make -s -C fw_arm fw_v2.elf

echo "== bridge2 DPI library =="
cc -shared -fPIC -O2 -Wall -I"$HOME/xezim/include" \
   bridge/xezim_bridge2.c -o build/bridge2.so

echo "== xezim (background, waits for Renode) =="
rm -f uart_v2.log
"$XEZIM" --simulate --sv2017 --error-exit \
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
