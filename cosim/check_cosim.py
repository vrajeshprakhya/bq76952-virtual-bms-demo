#!/usr/bin/env python3
"""Cross-domain checker for the Renode<->xezim co-simulation.

Cross-examines two independent witnesses -- the firmware's UART log
(the chip's story) and the xezim log (the board's story) -- and fails
if they disagree with each other or with the design's physics.  One
rule per layer of the stack:

  RULE1 protection   an overload must open DSG within 2 ms
  RULE2 telemetry    firmware-reported c1/i must match board physics
                     during the quiet 1 A phase (3688 mV, 1000 mA)
  RULE3 false trip   DSG must not open before the overload exists
  RULE4 bus/mission  no NACKs, no implausible readings, and the full
                     trip-and-recover mission must complete

(Named RULEn, not Rn: the schematic's resistors own the R refdes.)

Usage: check_cosim.py <uart.log> <xezim.log>
Exit 0 = all rules hold; exit 1 = at least one violation (printed).
"""
import re
import sys

uart_path, xezim_path = sys.argv[1], sys.argv[2]
U = open(uart_path, errors="replace").read()
X = open(xezim_path, errors="replace").read()

samples = [
    (float(t), int(ss), int(c1), int(i))
    for t, ss, c1, i in re.findall(
        r"\[fw t=([\d.]+)ms\] ss=0x(\d+) c1=(-?\d+)mV i=(-?\d+)mA", U)
]

def board_event_ms(pattern):
    m = re.search(pattern, X)
    return int(m.group(1)) / 1e9 if m else None   # xezim $time is ps

overload = board_event_ms(r"\[scenario\] t=(\d+): load raised")
dsg_open = board_event_ms(r"\[board\] t=(\d+): AFE opened DSG")

fails = []

# RULE1: protection must act on a real overload
if overload is not None and (dsg_open is None or dsg_open > overload + 2.0):
    opened = "never" if dsg_open is None else f"at {dsg_open:.2f}ms"
    fails.append(f"RULE1 protection-missing: overload at {overload:.0f}ms "
                 f"but DSG opened {opened} (required within 2ms)")

# RULE3: protection must not act without one
if dsg_open is not None and overload is not None and dsg_open < overload:
    fails.append(f"RULE3 false-trip: DSG opened at {dsg_open:.2f}ms, "
                 f"BEFORE the overload at {overload:.0f}ms")

# RULE2: chip-reported telemetry vs board physics in the quiet 1 A phase
quiet_end = min(x for x in (overload, dsg_open, 1e9) if x is not None)
quiet = [s for s in samples if s[0] < quiet_end]
for t, ss, c1, i in quiet:
    if not (3683 <= c1 <= 3693):
        fails.append(f"RULE2 telemetry: firmware says c1={c1}mV at t={t}ms; "
                     f"board truth is 3688 +/- 5")
        break
for t, ss, c1, i in quiet:
    if not (985 <= i <= 1015):
        fails.append(f"RULE2 telemetry: firmware says i={i}mA at t={t}ms; "
                     f"board truth is 1000 +/- 15")
        break

# RULE4: bus and mission health
if "I2C FAULT" in U:
    fails.append("RULE4 bus: firmware reported the slave not ACKing")
if "TELEMETRY FAULT" in U:
    fails.append("RULE4 plausibility: firmware flagged implausible telemetry")
if "RECOVERED" not in U:
    fails.append("RULE4 mission: trip-and-recover did not complete")

if fails:
    print(f"CHECK: FAIL ({len(fails)} rule violation(s))")
    for f in fails:
        print("  " + f)
    sys.exit(1)

print(f"CHECK: PASS  ({len(samples)} samples cross-checked; "
      f"trip {dsg_open - overload:.2f}ms after overload)")
