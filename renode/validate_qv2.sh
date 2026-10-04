#!/usr/bin/env bash
# Full validation of the bench-like mainline-QEMU backend:
#   1. determinism: two clean runs must produce identical uart+board logs
#   2. five-fault campaign (BACKEND=qv2)
#   3. clock-drift sweep (BACKEND=qv2)
set -u
cd "$(dirname "$0")"
overall=0

echo "=== 1. determinism ==="
# identity criterion: the two witnesses the checker judges -- the
# firmware's UART log and the board's event lines -- must be
# byte-identical.  The harness's own $finish timestamp is reported
# separately (sub-us tick-ledger rounding can move it by ~1 us).
bash run_cosim_qv2.sh > /tmp/qv2_r1.log 2>&1 || overall=1
cp -f ../logs_qv2/uart.log /tmp/qv2_uart1.log
grep -E 'scenario|board' ../logs_qv2/xezim.log > /tmp/qv2_board1.log
fin1=$(grep -oE 'finished at t=[0-9]+' ../logs_qv2/xezim.log)
bash run_cosim_qv2.sh > /tmp/qv2_r2.log 2>&1 || overall=1
cp -f ../logs_qv2/uart.log /tmp/qv2_uart2.log
grep -E 'scenario|board' ../logs_qv2/xezim.log > /tmp/qv2_board2.log
fin2=$(grep -oE 'finished at t=[0-9]+' ../logs_qv2/xezim.log)
if diff -q /tmp/qv2_uart1.log /tmp/qv2_uart2.log >/dev/null \
   && diff -q /tmp/qv2_board1.log /tmp/qv2_board2.log >/dev/null; then
  echo "DETERMINISM: PASS (uart log and board events byte-identical;"
  echo "  harness finish: $fin1 vs $fin2)"
else
  echo "DETERMINISM: FAIL"; overall=1
fi

echo "=== 2. fault campaign (qv2) ==="
BACKEND=qv2 bash run_faults.sh | tail -8 || overall=1

echo "=== 3. drift sweep (qv2) ==="
BACKEND=qv2 bash run_drift.sh | tail -8 || overall=1

if [ $overall -eq 0 ]; then echo "VALIDATE-QV2: PASS"; else echo "VALIDATE-QV2: FAIL"; exit 1; fi
