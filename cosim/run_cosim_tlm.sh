#!/usr/bin/env bash
# TLM-2.0 co-simulation: three host processes.
#   QEMU (unmodified mainline, same fw_qemu.elf, UART chardev :43603)
#     -> SystemC/TLM-2.0 shim (tlm_shim/shim.cpp): every firmware
#        action crosses a genuine IEEE 1666 TLM-2.0 target socket,
#        rnm_board_tlm, whose backend is...
#     -> xezim (:43601, byte-for-byte the v1 board server)
# Pass gate: the same cross-domain checker.
# Logs: ../logs_tlm/{xezim.log, shim.log, qemu.log, uart.log}
set -eu
cd "$(dirname "$0")"
XEZIM=${XEZIM:-$HOME/xezim/target/release/xezim}
QEMU=${QEMU:-$HOME/qemu-arm/bin/qemu-system-arm}
SCDIR=${SCDIR:-$HOME/systemc}
mkdir -p ../logs_tlm build

SCLIB="$SCDIR/lib-linux64"
[ -d "$SCLIB" ] || SCLIB="$SCDIR/lib"

echo "== firmware (ARM, QEMU flavour -- unchanged) =="
make -s -C fw_arm fw_qemu.elf

echo "== bridge DPI library =="
cc -shared -fPIC -O2 -Wall -I"$HOME/xezim/include" \
   bridge/xezim_bridge.c -o build/bridge.so

echo "== TLM-2.0 shim =="
g++ -std=c++17 -O2 -Wall -Wno-overloaded-virtual -I"$SCDIR/include" \
    tlm_shim/shim.cpp -o build/tlm_shim \
    -L"$SCLIB" -lsystemc -lpthread -Wl,-rpath,"$SCLIB"

echo "== xezim (background, board server :43601) =="
rm -f uart_tlm.log
"$XEZIM" --simulate --sv2017 --error-exit \
  -f xezim.f -s top_renode \
  --dpi-lib build/bridge.so \
  --max-time 400ms \
  > ../logs_tlm/xezim.log 2>&1 &
XPID=$!
sleep 1

echo "== TLM shim (background, :43603 -> :43601) =="
./build/tlm_shim 43603 43601 > ../logs_tlm/shim.log 2>&1 &
SPID=$!
sleep 1

echo "== QEMU (netduinoplus2, chardev -> shim) =="
"$QEMU" -M netduinoplus2 -kernel fw_arm/fw_qemu.elf \
  -chardev socket,id=br,host=127.0.0.1,port=43603,nodelay=on \
  -serial chardev:br \
  -serial file:uart_tlm.log \
  -display none -monitor none -semihosting \
  > ../logs_tlm/qemu.log 2>&1 || true

wait $XPID || true
wait $SPID || true
cp -f uart_tlm.log ../logs_tlm/uart.log 2>/dev/null || true

echo "---- firmware UART ----"
cat ../logs_tlm/uart.log
echo "---- board events (xezim) ----"
grep -E 'scenario|board|renode_bridge' ../logs_tlm/xezim.log || true
echo "---- TLM shim ----"
grep -E 'shim' ../logs_tlm/shim.log || true
echo "---- cross-domain check ----"
python3 check_cosim.py ../logs_tlm/uart.log ../logs_tlm/xezim.log
echo "COSIM-TLM: PASS"
