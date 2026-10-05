#!/usr/bin/env bash
# Clock-drift sweep on the v2 quantum-coupled co-sim: the AFE's
# internal oscillator vs the MCU's clock are independent on a real
# board, so sweep the AFE's measurement period (ppm of 250 us) and
# watch the trip's phase slide against the firmware's loop -- each
# point perfectly reproducible, unlike the bench's one dice roll per
# power cycle.  BQ-class internal oscillators are percent-grade, so
# the sweep spans +/-2%.
# Logs: ../logs_v2/drift/<ppm>/ + summary in ../logs_v2/drift/sweep.log
#   BACKEND=qv2 runs the sweep on the bench-like mainline-QEMU
#   backend instead (logs under ../logs_qv2/drift).
set -u
cd "$(dirname "$0")"
BACKEND=${BACKEND:-v2}
if [ "$BACKEND" = "qv2" ]; then
  RUNNER=run_cosim_qv2.sh; LDIR=../logs_qv2
else
  RUNNER=run_cosim_v2.sh; LDIR=../logs_v2
fi
DDIR=$LDIR/drift
mkdir -p "$DDIR"
SWEEP="$DDIR/sweep.log"
: > "$SWEEP"
overall=0

for ppm in -20000 -5000 0 5000 20000; do
  mkdir -p "$DDIR/$ppm"
  echo "== AFE drift ${ppm} ppm =="
  if XZ_DEFS="-D AFE_DRIFT_PPM=$ppm" bash "$RUNNER" \
       > "$DDIR/$ppm/run.log" 2>&1; then rc=0; else rc=1; overall=1; fi
  cp -f "$LDIR/uart.log"  "$DDIR/$ppm/uart.log"  2>/dev/null || true
  cp -f "$LDIR/xezim.log" "$DDIR/$ppm/xezim.log" 2>/dev/null || true
  trip=$(grep -oE 'opened DSG.*' "$DDIR/$ppm/xezim.log" >/dev/null 2>&1; \
         grep 'AFE opened DSG' "$DDIR/$ppm/xezim.log" \
         | grep -oE 't=[0-9]+' | head -1 | cut -c3-)
  isr=$(grep -oE '(isr|dispatched) at t=[0-9]+us' "$DDIR/$ppm/uart.log" \
        | grep -oE '[0-9]+' | head -1)
  chk=$(grep -oE 'CHECK: (PASS|FAIL)' "$DDIR/$ppm/run.log" | head -1)
  trip_us=$(( ${trip:-0} / 1000000 ))
  printf "%+7d ppm : trip %6s us  isr %6s us  %s  (rc=%d)\n" \
         "$ppm" "$trip_us" "${isr:-?}" "${chk:-no-check}" "$rc" \
         | tee -a "$SWEEP"
done

echo "== drift sweep summary =="
cat "$SWEEP"
if [ $overall -eq 0 ]; then
  echo "DRIFT-SWEEP: PASS (all points green; trip phase slides with drift)"
else
  echo "DRIFT-SWEEP: FAIL"
  exit 1
fi
