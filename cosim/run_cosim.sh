#!/usr/bin/env bash
# Renode <-> xezim co-simulation: real ARM firmware on an emulated
# STM32G0 drives the SV-RNM board over the socket bridge.
# Logs: ../logs_renode/{xezim.log, renode.log, uart.log}
#
# Fault-injection knobs (all default off; see run_faults.sh):
#   FW_FAULT=OCD_SWAP|REG_OFF1   firmware bug (compile-time define)
#   XZ_DEFS="-D FAULT_COFF"      board/RNM bug (xezim define)
#   BR_FAULT_SDA_STUCK=1         bridge/pin-path bug (env to xezim)
# The pass gate is check_cosim.py, which cross-examines the firmware's
# UART log against the board's own event log.
set -eu
cd "$(dirname "$0")"
XEZIM=${XEZIM:-$HOME/xezim/target/release/xezim}
RENODE=${RENODE:-$HOME/renode-portable/renode}
FW_FAULT=${FW_FAULT:-}
XZ_DEFS=${XZ_DEFS:-}
BR_FAULT_SDA_STUCK=${BR_FAULT_SDA_STUCK:-0}
mkdir -p ../logs_renode build

echo "== firmware (ARM)${FW_FAULT:+  [FAULT_$FW_FAULT]} =="
make -s -C fw_arm FAULT="$FW_FAULT"

echo "== bridge DPI library =="
cc -shared -fPIC -O2 -Wall -I"$HOME/xezim/include" \
   bridge/xezim_bridge.c -o build/bridge.so

BRTAG=""; [ "$BR_FAULT_SDA_STUCK" = "1" ] && BRTAG="  [BR_FAULT_SDA_STUCK]"
echo "== xezim (background, waits for Renode)${XZ_DEFS:+  [$XZ_DEFS]}$BRTAG =="
rm -f uart.log
BR_FAULT_SDA_STUCK="$BR_FAULT_SDA_STUCK" \
"$XEZIM" --simulate --sv2017 --error-exit \
  $XZ_DEFS \
  -f xezim.f -s top_renode \
  --dpi-lib build/bridge.so \
  --max-time 400ms \
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
grep -E 'scenario|board|renode_bridge|FAULT' ../logs_renode/xezim.log || true
echo "---- cross-domain check ----"
python3 check_cosim.py ../logs_renode/uart.log ../logs_renode/xezim.log
echo "COSIM: PASS"
