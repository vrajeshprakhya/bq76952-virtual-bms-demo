#!/usr/bin/env python3
"""Cross-domain checker for the load-cell (HX717) co-simulation.
Two witnesses, same discipline as the BMS checker: the firmware's
UART log vs the board's event log, graded against the chain's
physics.  Expected step delta: 2 mV/V x 5 V x (2000/5000) = 4 mV
into a 0.5*5V/128 = 19.531 mV full scale -> 1,717,987 counts.

  S1 quiet scale: pre-step deltas within noise of zero
  S2 physics: post-step steady delta = 1,717,987 within 1%
  S3 detection: the firmware's WEIGHT event lands within 10 ms of
     the board's force step
  S4 mission completes; no HX717 power-down events

Usage: check_spi.py <uart.log> <xezim.log>
"""
import re
import sys

EXPECTED = 1717987
uart_path, xezim_path = sys.argv[1], sys.argv[2]
U = open(uart_path, errors="replace").read()
X = open(xezim_path, errors="replace").read()

samples = [
    (float(t), int(n), int(c), int(d))
    for t, n, c, d in re.findall(
        r"\[fw t=([\d.]+)ms\] n=(\d+) counts=(-?\d+) delta=(-?\d+)", U)
]

m = re.search(r"\[scenario\] t=(\d+): force step", X)
step_ms = int(m.group(1)) / 1e9 if m else None

m = re.search(r"WEIGHT detected.*", U)
det_ms = None
if m:
    m2 = re.search(r"\[fw t=([\d.]+)ms\] \*\*\* WEIGHT", U)
    det_ms = float(m2.group(1)) if m2 else None

fails = []

pre = [s for s in samples if step_ms is not None and s[0] < step_ms]
for t, n, c, d in pre:
    if abs(d) > 3000:
        fails.append(f"S1 quiet: delta={d} at t={t}ms on an empty "
                     f"scale (noise budget 3000)")
        break

post = [s for s in samples
        if step_ms is not None and s[0] > step_ms + 8.0]
if post:
    d = post[-1][3]
    if abs(d - EXPECTED) > EXPECTED * 0.01:
        fails.append(f"S2 physics: steady delta={d}, expected "
                     f"{EXPECTED} +/- 1%")
else:
    fails.append("S2 physics: no post-step samples")

if step_ms is None:
    fails.append("S3 detection: board never stepped the force")
elif det_ms is None:
    fails.append("S3 detection: firmware never detected the weight")
elif not (step_ms <= det_ms <= step_ms + 10.0):
    fails.append(f"S3 detection: detected at {det_ms}ms, step at "
                 f"{step_ms}ms (must be within 10 ms)")

if "mission complete" not in U:
    fails.append("S4 mission: did not complete")
if "POWER-DOWN" in X:
    fails.append("S4 bus: HX717 power-down (SCLK held high)")

if fails:
    print(f"CHECK: FAIL ({len(fails)} rule violation(s))")
    for f in fails:
        print("  " + f)
    sys.exit(1)

print(f"CHECK: PASS  ({len(samples)} samples; detection "
      f"{det_ms - step_ms:.2f}ms after the step; steady delta "
      f"{post[-1][3]} vs {EXPECTED} expected)")
