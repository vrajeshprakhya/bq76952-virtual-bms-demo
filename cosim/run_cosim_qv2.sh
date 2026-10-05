#!/usr/bin/env bash
# BENCH-LIKE co-simulation on UNMODIFIED mainline QEMU.
#   QEMU runs with icount (deterministic virtual time); the firmware
#   meters its own measured execution to the board as time beacons
#   over the UART bridge; the board's ALERT rides every ack and is
#   dispatched within ~10 us.  Board: top_v2 + bridge2 (port 43602),
#   unchanged.  Pass gate: the same cross-domain checker.
# Knobs: FW_FAULT=, XZ_DEFS="-D FAULT_COFF" / "-D AFE_DRIFT_PPM=<n>",
#        BR_FAULT_SDA_STUCK=1
# Logs: ../logs_qv2/{xezim.log, qemu.log, uart.log}
set -eu
cd "$(dirname "$0")"
XEZIM=${XEZIM:-$HOME/xezim/target/release/xezim}
QEMU=${QEMU:-$HOME/qemu-arm/bin/qemu-system-arm}
FW_FAULT=${FW_FAULT:-}
XZ_DEFS=${XZ_DEFS:-}
BR_FAULT_SDA_STUCK=${BR_FAULT_SDA_STUCK:-0}
mkdir -p ../logs_qv2 build

echo "== firmware (ARM, bench-like QEMU flavour)${FW_FAULT:+  [FAULT_$FW_FAULT]} =="
make -s -C fw_arm fw_qv2.elf FAULT="$FW_FAULT"

echo "== bridge2 DPI library =="
cc -shared -fPIC -O2 -Wall -I"$HOME/xezim/include" \
   bridge/xezim_bridge2.c -o build/bridge2.so

BRTAG=""; [ "$BR_FAULT_SDA_STUCK" = "1" ] && BRTAG="  [BR_FAULT_SDA_STUCK]"
echo "== xezim (background, board server :43602)${XZ_DEFS:+  [$XZ_DEFS]}$BRTAG =="
rm -f uart_qv2.log
BR_FAULT_SDA_STUCK="$BR_FAULT_SDA_STUCK" \
"$XEZIM" --simulate --sv2017 --error-exit \
  $XZ_DEFS \
  -f xezim_v2.f -s top_v2 \
  --dpi-lib build/bridge2.so \
  --max-time 400ms \
  > ../logs_qv2/xezim.log 2>&1 &
XPID=$!
sleep 1

echo "== QEMU (netduinoplus2, icount shift=3, deterministic) =="
"$QEMU" -M netduinoplus2 -kernel fw_arm/fw_qv2.elf \
  -icount shift=3,sleep=off \
  -chardev socket,id=br,host=127.0.0.1,port=43602,nodelay=on \
  -serial chardev:br \
  -serial file:uart_qv2.log \
  -display none -monitor none -semihosting \
  > ../logs_qv2/qemu.log 2>&1 || true

wait $XPID || true
cp -f uart_qv2.log ../logs_qv2/uart.log 2>/dev/null || true

echo "---- firmware UART ----"
cat ../logs_qv2/uart.log
echo "---- board events (xezim) ----"
grep -E 'scenario|board|renode_bridge' ../logs_qv2/xezim.log || true
echo "---- cross-domain check ----"
python3 check_cosim.py ../logs_qv2/uart.log ../logs_qv2/xezim.log
echo "COSIM-QV2: PASS"
