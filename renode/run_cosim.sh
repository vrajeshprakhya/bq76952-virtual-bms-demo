#!/usr/bin/env bash
# Renode <-> xezim co-simulation: real ARM firmware on an emulated
# STM32F4 drives the SV-RNM board over the socket bridge.
# Logs: ../logs_renode/{xezim.log, renode.log, uart.log}
set -eu
cd "$(dirname "$0")"
XEZIM=${XEZIM:-$HOME/xezim/target/release/xezim}
RENODE=${RENODE:-$HOME/renode-portable/renode}
mkdir -p ../logs_renode build

echo "== firmware (ARM) =="
make -s -C fw_arm

echo "== bridge DPI library =="
cc -shared -fPIC -O2 -Wall -I"$HOME/xezim/include" \
   bridge/xezim_bridge.c -o build/bridge.so

echo "== xezim (background, waits for Renode) =="
rm -f uart.log
"$XEZIM" --simulate --sv2017 --error-exit \
  -f xezim.f -s top_renode \
  --dpi-lib build/bridge.so \
  --max-time 200ms \
  > ../logs_renode/xezim.log 2>&1 &
XPID=$!
sleep 1

echo "== Renode (console) =="
"$RENODE" --console --disable-xwt cosim.resc \
  > ../logs_renode/renode.log 2>&1 || true

wait $XPID || true
cp -f uart.log ../logs_renode/uart.log 2>/dev/null || true

echo "---- firmware UART ----"
cat ../logs_renode/uart.log
echo "---- board events (xezim) ----"
grep -E 'scenario|board|renode_bridge|TCD|OCD' ../logs_renode/xezim.log || true
grep -q 'RECOVERED' ../logs_renode/uart.log
echo "COSIM: PASS"
