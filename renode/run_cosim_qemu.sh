#!/usr/bin/env bash
# Mainline-QEMU <-> xezim co-simulation: the same mission firmware,
# compiled for STM32F405 (machine netduinoplus2), drives the same
# SV-RNM board through the same xezim bridge server -- the co-sim
# channel rides USART1, whose chardev is a TCP socket (zero QEMU
# modifications).  Pass gate: the same cross-domain checker.
# Logs: ../logs_qemu/{xezim.log, qemu.log, uart.log}
set -eu
cd "$(dirname "$0")"
XEZIM=${XEZIM:-$HOME/xezim/target/release/xezim}
QEMU=${QEMU:-$HOME/qemu-arm/bin/qemu-system-arm}
mkdir -p ../logs_qemu build

echo "== firmware (ARM, QEMU flavour) =="
make -s -C fw_arm fw_qemu.elf

echo "== bridge DPI library =="
cc -shared -fPIC -O2 -Wall -I"$HOME/xezim/include" \
   bridge/xezim_bridge.c -o build/bridge.so

echo "== xezim (background, waits for QEMU) =="
rm -f uart_qemu.log
"$XEZIM" --simulate --sv2017 --error-exit \
  -f xezim.f -s top_renode \
  --dpi-lib build/bridge.so \
  --max-time 400ms \
  > ../logs_qemu/xezim.log 2>&1 &
XPID=$!
sleep 1

echo "== QEMU (netduinoplus2) =="
"$QEMU" -M netduinoplus2 -kernel fw_arm/fw_qemu.elf \
  -chardev socket,id=br,host=127.0.0.1,port=43601,nodelay=on \
  -serial chardev:br \
  -serial file:uart_qemu.log \
  -display none -monitor none -semihosting \
  > ../logs_qemu/qemu.log 2>&1 || true

wait $XPID || true
cp -f uart_qemu.log ../logs_qemu/uart.log 2>/dev/null || true

echo "---- firmware UART ----"
cat ../logs_qemu/uart.log
echo "---- board events (xezim) ----"
grep -E 'scenario|board|renode_bridge' ../logs_qemu/xezim.log || true
echo "---- cross-domain check ----"
python3 check_cosim.py ../logs_qemu/uart.log ../logs_qemu/xezim.log
echo "COSIM-QEMU: PASS"
