#!/usr/bin/env bash
# The QEMU bench-like mission on a board top GENERATED from the
# schematic (spice2rnm board mode + part library + MCU pad map +
# scenario), instead of the hand-written top_v2.sv. Same firmware, same
# QEMU, same bridge, same checker as run_cosim_qv2.sh.
# Knobs: DNP="R12 ..." (parts left unpopulated), FW_FAULT=, XZ_DEFS=
# Logs: ../logs_bench${DNP:+_dnp}/{bench_report.txt, xezim.log, qemu.log, uart.log}
set -eu
cd "$(dirname "$0")"
XEZIM=${XEZIM:-$HOME/xezim/target/release/xezim}
QEMU=${QEMU:-$HOME/qemu-arm/bin/qemu-system-arm}
S2R=${S2R:-$HOME/spice2rnm}
FW_FAULT=${FW_FAULT:-}
XZ_DEFS=${XZ_DEFS:-}
DNP=${DNP:-}
export PATH="$HOME/ngspice-install/bin:$PATH"
TAG=""; for d in $DNP; do TAG="${TAG}_dnp_$d"; done
LOG=../logs_bench$TAG
GEN=build/bench$TAG
mkdir -p "$LOG" build

echo "== generate the board top from the schematic${DNP:+  [DNP: $DNP]} =="
dnp_args=""; for d in $DNP; do dnp_args="$dnp_args --dnp $d"; done
( cd "$S2R" && python3 -m spice2rnm.board.bench \
    "$OLDPWD/../kicad/bms_6s_fab.cir" \
    --parts "$OLDPWD/../partlib/parts.json" \
    --mcu "$OLDPWD/bench_mcu_qv2.json" \
    --scenario "$OLDPWD/bench_scenario_qv2.json" \
    --out "$OLDPWD/$GEN" $dnp_args ) > "$LOG/bench_report.txt" 2>&1 \
  || { cat "$LOG/bench_report.txt"; exit 1; }
cat "$LOG/bench_report.txt"
cp -f "$GEN/bench_top.sv" "$LOG/"

echo "== firmware (ARM, bench-like QEMU flavour)${FW_FAULT:+  [FAULT_$FW_FAULT]} =="
make -s -C fw_arm fw_qv2.elf FAULT="$FW_FAULT"

echo "== bridge2 DPI library =="
cc -shared -fPIC -O2 -Wall -I"$HOME/xezim/include" \
   bridge/xezim_bridge2.c -o build/bridge2.so

echo "== xezim (background, generated board, :43602)${XZ_DEFS:+  [$XZ_DEFS]} =="
rm -f uart_bench.log
"$XEZIM" --simulate --sv2017 --error-exit \
  $XZ_DEFS \
  -f "$GEN/bench.f" -s bench_top \
  --dpi-lib build/bridge2.so \
  --max-time 400ms \
  > "$LOG/xezim.log" 2>&1 &
XPID=$!
sleep 1

echo "== QEMU (netduinoplus2, icount shift=3, deterministic) =="
timeout 600 "$QEMU" -M netduinoplus2 -kernel fw_arm/fw_qv2.elf \
  -icount shift=3,sleep=off \
  -chardev socket,id=br,host=127.0.0.1,port=43602,nodelay=on \
  -serial chardev:br \
  -serial file:uart_bench.log \
  -display none -monitor none -semihosting \
  > "$LOG/qemu.log" 2>&1 || true

wait $XPID || true
cp -f uart_bench.log "$LOG/uart.log" 2>/dev/null || true

echo "---- firmware UART ----"
cat "$LOG/uart.log"
echo "---- board events (xezim) ----"
grep -E 'scenario|\[board\]|renode_bridge|rror' "$LOG/xezim.log" || true
echo "---- cross-domain check ----"
python3 check_cosim.py "$LOG/uart.log" "$LOG/xezim.log"
echo "COSIM-BENCH: PASS"
