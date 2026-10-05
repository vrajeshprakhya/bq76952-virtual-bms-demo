#!/usr/bin/env bash
# I2C DRIVER RUNG: the firmware uses the STM32 G0's real I2C1
# controller (Renode model); the harness executes every byte-level
# transaction as pin-level edges on the unchanged SV-RNM board over
# the generic pin bridge.  Same mission, same checker.
# Logs: ../logs_i2cdrv/{xezim.log, renode.log, uart.log}
set -eu
cd "$(dirname "$0")"
XEZIM=${XEZIM:-$HOME/xezim/target/release/xezim}
RENODE=${RENODE:-$HOME/renode-portable/renode}
mkdir -p ../logs_i2cdrv build

echo "== firmware (ARM, real I2C1 driver) =="
make -s -C fw_arm fw_i2cdrv.elf

echo "== generic bridge DPI library =="
cc -shared -fPIC -O2 -Wall -I"$HOME/xezim/include" \
   bridge/xezim_bridge_g.c -o build/bridge_g.so

echo "== xezim (background, board :43605) =="
rm -f uart_i2cdrv.log
"$XEZIM" --simulate --sv2017 --error-exit \
  -f xezim_i2cdrv.f -s top_i2cdrv \
  --dpi-lib build/bridge_g.so \
  --max-time 400ms \
  > ../logs_i2cdrv/xezim.log 2>&1 &
XPID=$!
sleep 1

echo "== Renode (console) =="
"$RENODE" --console --disable-xwt cosim_i2cdrv.resc \
  > ../logs_i2cdrv/renode.log 2>&1 || true

wait $XPID || true
cp -f uart_i2cdrv.log ../logs_i2cdrv/uart.log 2>/dev/null || true

echo "---- firmware UART ----"
cat ../logs_i2cdrv/uart.log
echo "---- board events (xezim) ----"
grep -E 'scenario|board|pin_bridge' ../logs_i2cdrv/xezim.log || true
echo "---- cross-domain check ----"
python3 check_cosim.py ../logs_i2cdrv/uart.log ../logs_i2cdrv/xezim.log
echo "COSIM-I2CDRV: PASS"
