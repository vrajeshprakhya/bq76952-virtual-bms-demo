#!/usr/bin/env bash
# Fault-injection campaign for the co-simulation framework: inject one
# defect per layer of the stack and prove the cross-domain checker
# catches each one by a DIFFERENT rule -- then prove the clean setup
# still passes.
#
#   clean       no fault                          -> CHECK: PASS
#   fw_cfg      firmware: OCD threshold write byte-swapped       -> R1
#   fw_proto    firmware: cell readout off-by-one register       -> R2
#   board       RNM: +2500 mA offset in the analog current path  -> R3
#   bridge      SDA readback stuck (pin-mux class of bug)        -> R4
#
# Logs per run: ../logs_renode/faults/<name>/{uart,xezim,check}.log
# Summary: ../logs_renode/faults/summary.log
#   BACKEND=qemu runs the campaign on the QEMU backend instead
#   (run_cosim_qemu.sh, logs under ../logs_qemu/faults).
set -u
cd "$(dirname "$0")"
BACKEND=${BACKEND:-renode}
if [ "$BACKEND" = "qemu" ]; then
  RUNNER=run_cosim_qemu.sh; LDIR=../logs_qemu
elif [ "$BACKEND" = "v2" ]; then
  RUNNER=run_cosim_v2.sh; LDIR=../logs_v2
elif [ "$BACKEND" = "qv2" ]; then
  RUNNER=run_cosim_qv2.sh; LDIR=../logs_qv2
else
  RUNNER=run_cosim.sh; LDIR=../logs_renode
fi
FDIR=$LDIR/faults
mkdir -p "$FDIR"
SUMMARY="$FDIR/summary.log"
: > "$SUMMARY"
overall=0

run_one() {  # name expected_rule FW_FAULT XZ_DEFS BR_STUCK
  local name=$1 expect=$2 fw=$3 xz=$4 br=$5
  mkdir -p "$FDIR/$name"
  echo "=============================================================="
  echo "== $name  (expect: $expect)"
  if FW_FAULT="$fw" XZ_DEFS="$xz" BR_FAULT_SDA_STUCK="$br" \
       bash "$RUNNER" > "$FDIR/$name/run.log" 2>&1; then
    rc=0
  else
    rc=1
  fi
  cp -f "$LDIR/uart.log"  "$FDIR/$name/uart.log"  2>/dev/null || true
  cp -f "$LDIR/xezim.log" "$FDIR/$name/xezim.log" 2>/dev/null || true
  grep -E 'CHECK:|R[1-4] ' "$FDIR/$name/run.log" > "$FDIR/$name/check.log" || true
  cat "$FDIR/$name/check.log"

  local verdict
  if [ "$expect" = "PASS" ]; then
    if [ $rc -eq 0 ]; then verdict="OK: clean setup passes"
    else verdict="PROBLEM: clean setup failed"; overall=1; fi
  else
    if [ $rc -ne 0 ] && grep -q "$expect " "$FDIR/$name/check.log"; then
      verdict="CAUGHT by $expect"
    elif [ $rc -ne 0 ]; then
      verdict="caught, but not by $expect (see check.log)"; overall=1
    else
      verdict="MISSED: fault ran clean"; overall=1
    fi
  fi
  echo "-> $verdict"
  printf "%-8s expect %-4s : %s\n" "$name" "$expect" "$verdict" >> "$SUMMARY"
}

run_one clean    PASS ""         ""              0
run_one fw_cfg   R1   OCD_SWAP   ""              0
run_one fw_proto R2   REG_OFF1   ""              0
run_one board    R3   ""         "-D FAULT_COFF" 0
run_one bridge   R4   ""         ""              1

echo "=============================================================="
echo "== campaign summary"
cat "$SUMMARY"
if [ $overall -eq 0 ]; then
  echo "FAULT-CAMPAIGN: PASS (clean passes; every fault caught by its own rule)"
else
  echo "FAULT-CAMPAIGN: FAIL"
  exit 1
fi
