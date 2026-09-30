#!/usr/bin/env python3
"""Functional connectivity check for bms_6s_fab.kicad_sch.

Parses the netlist EXPORTED BY KICAD (bms_6s_fab.xml, kicadxml format)
and compares it against GOLDEN -- the intended functional connectivity
of the board, written out pin by pin.  This is the check the label-
based drawing style needs: ERC proves nothing dangles; this proves the
labels join the pins they were meant to join.  Geometry bugs (a label
missing a wire end), net-name typos, and later GUI edits all land here
as a diff.

Run after every schematic change:
    kicad-cli sch export netlist --format kicadxml -o bms_6s_fab.xml bms_6s_fab.kicad_sch
    python3 check_netlist.py
"""
import re, sys, xml.etree.ElementTree as ET

GOLDEN = {
    # net              : exact set of ref.pin members
    "SDA"              : {"U1.4", "U2.46", "R12.2"},
    "SCL"              : {"U1.5", "U2.45", "R13.2"},
    "ALERT"            : {"U1.30", "U2.11"},
    "SRP"              : {"U1.28", "R5.2", "C7.1"},
    "SRN"              : {"U1.29", "R6.2", "C7.2"},
    "SRP_K"            : {"RS1.3", "R5.1"},
    "SRN_K"            : {"RS1.2", "R6.1"},
    "SRB"              : {"RS1.4", "Q1.S", "R8.2"},
    "FETMID"           : {"Q1.D", "Q2.D"},
    "PACK_M"           : {"Q2.S", "R10.2", "J2.2"},
    "DSG_DRV"          : {"U1.1", "R7.1"},
    "CHG_DRV"          : {"U1.2", "R9.1"},
    "DSG_G"            : {"Q1.G", "R7.2", "R8.1"},
    "CHG_G"            : {"Q2.G", "R9.2", "R10.1"},
    "TS1"              : {"U1.6", "TH1.1", "C6.1"},
    "CAP1"             : {"U1.7", "C4.1"},
    "CAP2"             : {"U1.14", "C5.1"},
    "BATRC"            : {"U1.15", "R1.2", "C1.1"},
    "REGSRC"           : {"U1.9", "R2.2", "C2.1"},
    "+3V3REG"          : {"U1.8", "C3.1", "R3.1"},
    "VREFP"            : {"U2.5", "R11.2", "C11.1"},
    "NRST"             : {"U2.10", "C12.1", "J3.4"},
    "SWDIO"            : {"U2.35", "J3.2"},
    "SWCLK"            : {"U2.36", "J3.3"},
    "+3V3_SWD"         : {"J3.1", "R14.2"},
    "LED"              : {"U2.16", "R15.1"},
    "LEDK"             : {"R15.2", "D1.2"},
    # cell taps and filters
    "B1"               : {"J1.2", "RF1.1"},
    "B2"               : {"J1.3", "RF2.1"},
    "B3"               : {"J1.4", "RF3.1", "RF4.1"},
    "B4"               : {"J1.5", "RF5.1"},
    "B5"               : {"J1.6", "RF6.1"},
    "VC0F"             : {"RF0.2", "U1.27", "CF1.2"},
    "VC1F"             : {"RF1.2", "U1.26", "CF1.1", "CF2.2"},
    "VC2F"             : {"RF2.2", "U1.25", "CF2.1", "CF3.2"},
    "VC3F"             : {"RF3.2", "U1.24", "U1.23", "U1.22", "CF3.1"},
    "VC5BF"            : {"RF4.2", "U1.21", "U1.10", "CF4.2"},
    "VC6F"             : {"RF5.2", "U1.20", "CF4.1", "CF5.2"},
    "VC7F"             : {"RF6.2", "U1.19", "CF5.1", "CF6.2"},
    "VC8F"             : {"RF7.2", "U1.18", "U1.17", "U1.16", "CF6.1"},
}
# nets whose membership is checked as a SUBSET (power symbols and
# flags also join them; refs #PWR/#FLG are stripped before compare)
GOLDEN_SUBSET = {
    "GND"  : {"U1.3", "U2.7", "J1.1", "RS1.1", "RF0.1", "TH1.2",
              "C1.2", "C2.2", "C3.2", "C4.2", "C5.2", "C6.2",
              "C8.2", "C9.2", "C10.2", "C11.2", "C12.2",
              "D1.1", "J3.5"},
    "+3V3" : {"R3.2", "R11.1", "R12.1", "R13.1", "R14.1",
              "C8.1", "C9.1", "C10.1", "U2.4", "U2.6"},
    "B6"   : {"J1.7", "RF7.1", "R1.1", "R2.1", "J2.1"},
}

tree = ET.parse("bms_6s_fab.xml")
nets = {}
for net in tree.iter("net"):
    # local labels export sheet-scoped ("/SDA" on the root sheet);
    # global power nets stay bare.  Normalize to the bare name.
    name = net.get("name").lstrip("/")
    members = {f'{n.get("ref")}.{n.get("pin")}' for n in net.iter("node")}
    nets[name] = nets.get(name, set()) | members

def visible(members):
    return {m for m in members if not m.startswith(("#PWR", "#FLG"))}

fails = 0
for name, want in GOLDEN.items():
    got = visible(nets.get(name, set()))
    if got != want:
        fails += 1
        print(f"FAIL {name}:")
        print(f"     missing: {sorted(want - got)}")
        print(f"     extra:   {sorted(got - want)}")
for name, want in GOLDEN_SUBSET.items():
    got = visible(nets.get(name, set()))
    if not want <= got:
        fails += 1
        print(f"FAIL {name} (subset): missing {sorted(want - got)}")

# every net in the export must be known (catches label typos that
# create plausible-looking strays)
known = set(GOLDEN) | set(GOLDEN_SUBSET)
for name, members in nets.items():
    if name in known or name.startswith("unconnected-"):
        continue
    fails += 1
    print(f"FAIL stray net {name}: {sorted(visible(members))}")

total = len(GOLDEN) + len(GOLDEN_SUBSET)
if fails:
    print(f"\nNETLIST CHECK: {fails} problem(s) across {total} golden nets")
    sys.exit(1)
print(f"NETLIST CHECK: OK -- {total} golden nets, "
      f"{len(nets)} nets in export, all accounted for")
