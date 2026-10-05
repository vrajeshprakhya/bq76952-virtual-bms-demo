#!/usr/bin/env bash
# TRANSPORTABILITY PROOF: a second protocol (HX717 load-cell ADC,
# SPI-family two-wire) on the same framework -- generic pin-vector
# bridge, bench-like time on unmodified mainline QEMU + icount, the
# same two-witness checking discipline.
# Logs: ../logs_spi/{xezim.log, qemu.log, uart.log}
set -eu
cd "$(dirname "$0")"
XEZIM=${XEZIM:-$HOME/xezim/target/release/xezim}
QEMU=${QEMU:-$HOME/qemu-arm/bin/qemu-system-arm}
mkdir -p ../logs_spi build

echo "== firmware (ARM, load-cell mission) =="
make -s -C fw_arm fw_spi.elf

echo "== generic bridge DPI library =="
cc -shared -fPIC -O2 -Wall -I"$HOME/xezim/include" \
   bridge/xezim_bridge_g.c -o build/bridge_g.so

echo "== xezim (background, load-cell board :43604) =="
rm -f uart_spi.log
"$XEZIM" --simulate --sv2017 --error-exit \
  -f xezim_spi.f -s top_spi \
  --dpi-lib build/bridge_g.so \
  --max-time 600ms \
  > ../logs_spi/xezim.log 2>&1 &
XPID=$!
sleep 1

echo "== QEMU (netduinoplus2, icount) =="
"$QEMU" -M netduinoplus2 -kernel fw_arm/fw_spi.elf \
  -icount shift=3,sleep=off \
  -chardev socket,id=br,host=127.0.0.1,port=43604,nodelay=on \
  -serial chardev:br \
  -serial file:uart_spi.log \
  -display none -monitor none -semihosting \
  > ../logs_spi/qemu.log 2>&1 || true

wait $XPID || true
cp -f uart_spi.log ../logs_spi/uart.log 2>/dev/null || true

echo "---- firmware UART (head/tail) ----"
head -8 ../logs_spi/uart.log
echo "..."
tail -6 ../logs_spi/uart.log
echo "---- board events (xezim) ----"
grep -E 'scenario|HX717|pin_bridge' ../logs_spi/xezim.log || true
echo "---- cross-domain check ----"
python3 check_spi.py ../logs_spi/uart.log ../logs_spi/xezim.log
echo "COSIM-SPI: PASS"
