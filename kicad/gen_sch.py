#!/usr/bin/env python3
"""Generate bms_6s_fab.kicad_sch -- fabrication-grade schematic of the
6S BMS board (BQ76930 AFE + STM32G0B1 host), from the OFFICIAL KiCad
symbol libraries (tag 9.0.0, fetched by fetch_libs.sh).

Style: every pin is either wired to a short stub + net label, tied to a
power symbol, or explicitly marked no-connect.  All passives are placed
unrotated; connectivity is by net label (accepted practice), so the
sheet is ERC-checkable and every net is greppable by name.

Substitution note (also printed on the sheet): the behavioural model in
design/ is BQ76952-class; the official symbol library carries only the
BQ769x0 family, so the fab sheet instantiates the member sized for 6S,
the BQ76930 (6-10 cells, I2C, CHG/DSG drivers, SRP/SRN, TS, internal
balancing) -- feature-for-feature what the demo exercises.
"""
import re, uuid, sys

import os
# Prefer the symbol libraries of the locally installed KiCad (exact
# match for what renders/ERCs); fall back to the fetched tag-9.0.0
# copies in libs/ (fetch_libs.sh) on machines without KiCad.
_INSTALLED = "/mnt/c/Users/vraje/AppData/Local/Programs/KiCad/10.0/share/kicad/symbols"
LIBDIR = _INSTALLED if os.path.isdir(_INSTALLED) else "libs"
print(f"symbol source: {LIBDIR}")
OUT = "bms_6s_fab.kicad_sch"
ROOT_UUID = "a0b1c2d3-0001-4000-8000-bq6sfabsheet".replace("bq6sfabsheet", "000000000001")
PROJ = "bms_6s_fab"

# ---------------------------------------------------------------- lib
def read(lib):
    return open(f"{LIBDIR}/{lib}.kicad_sym").read()

def block(text, name):
    key = f'(symbol "{name}"'
    i = text.index(key)
    d = 0
    for j in range(i, len(text)):
        if text[j] == '(':
            d += 1
        elif text[j] == ')':
            d -= 1
            if d == 0:
                return text[i:j + 1]
    raise RuntimeError(name)

LIBS = {n: read(n) for n in
        ["Battery_Management", "MCU_ST_STM32G0", "Device",
         "Connector_Generic", "power"]}

NEED = [
    ("Battery_Management", "BQ76930DBT"),
    ("MCU_ST_STM32G0", "STM32G0B1C_B-C-E_Tx"),
    ("Device", "R"), ("Device", "C"), ("Device", "R_Shunt"),
    ("Device", "Q_NMOS"), ("Device", "Thermistor_NTC"), ("Device", "LED"),
    ("Connector_Generic", "Conn_01x07"),
    ("Connector_Generic", "Conn_01x02"),
    ("Connector_Generic", "Conn_01x05"),
    ("power", "GND"), ("power", "+3V3"), ("power", "PWR_FLAG"),
]

SYM = {}          # "Lib:Name" -> block text (prefixed)
PINS = {}         # "Lib:Name" -> {number: (x, y, ang)}

PIN_RE = re.compile(
    r'\(pin\s+\w+\s+\w+\s*\(at\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\)'
    r'.*?\(number\s+"([^"]+)"', re.S)

for lib, name in NEED:
    b = block(LIBS[lib], name)
    pref = f"{lib}:{name}"
    SYM[pref] = b.replace(f'(symbol "{name}"', f'(symbol "{pref}"', 1)
    PINS[pref] = {m.group(4): (float(m.group(1)), float(m.group(2)),
                               int(m.group(3)))
                  for m in PIN_RE.finditer(b)}

# ------------------------------------------------------------ emitters
_uid = 0
def uid():
    global _uid
    _uid += 1
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"bq6sfab-{_uid}"))

parts = []      # symbol instances
graph = []      # wires / labels / no-connects / text / power symbols

def esc(s):
    return s.replace('"', '\\"')

def snap(v):
    """KiCad connection grid is 1.27 mm (50 mil)"""
    return round(round(v / 1.27) * 1.27, 2)

class Part:
    def __init__(self, libid, ref, value, x, y, footprint="", dnp=False):
        self.libid, self.ref, self.value = libid, ref, value
        self.x, self.y, self.fp, self.dnp = snap(x), snap(y), footprint, dnp
        parts.append(self)

    def pin(self, num):
        px, py, ang = PINS[self.libid][str(num)]
        return (round(self.x + px, 2), round(self.y - py, 2), ang)

    def emit(self):
        pins = "".join(f'\n    (pin "{n}" (uuid "{uid()}"))'
                       for n in PINS[self.libid])
        hid = " (hide yes)" if self.ref.startswith("#") else ""
        # big parts: name/value above the symbol, clear of pin text
        big = self.ref in ("U1", "U2")
        ry = self.y - (34 if self.ref == "U1" else 56) if big else self.y - 4
        vy = ry + 4 if big else self.y + 4
        rx = self.x - 10 if big else self.x + 2
        return f'''
  (symbol (lib_id "{self.libid}") (at {self.x} {self.y} 0) (unit 1)
    (exclude_from_sim no) (in_bom yes) (on_board yes) (dnp {"yes" if self.dnp else "no"})
    (uuid "{uid()}")
    (property "Reference" "{self.ref}" (at {rx} {ry} 0)
      (effects (font (size 1.27 1.27)) (justify left){hid}))
    (property "Value" "{esc(self.value)}" (at {rx} {vy} 0)
      (effects (font (size 1.27 1.27)) (justify left){hid}))
    (property "Footprint" "{self.fp}" (at {self.x} {self.y} 0)
      (effects (font (size 1.27 1.27)) (hide yes)))
    (property "Datasheet" "" (at {self.x} {self.y} 0)
      (effects (font (size 1.27 1.27)) (hide yes))){pins}
    (instances (project "{PROJ}"
      (path "/{ROOT_UUID}" (reference "{self.ref}") (unit 1)))))'''

def stub_end(p):
    x, y, ang = p
    # lib pin angle points from the connection point INTO the body;
    # in schematic space (y down) the outward direction is:
    dx, dy = {0: (-1, 0), 180: (1, 0), 90: (0, 1), 270: (0, -1)}[ang]
    L = 2.54
    return (round(x + dx * L, 2), round(y + dy * L, 2), dx, dy)

def wire(a, b):
    graph.append(f'\n  (wire (pts (xy {a[0]} {a[1]}) (xy {b[0]} {b[1]}))'
                 f' (stroke (width 0) (type default)) (uuid "{uid()}"))')

def net(part, pin, name):
    p = part.pin(pin)
    ex, ey, dx, dy = stub_end(p)
    wire(p, (ex, ey))
    just = "right" if dx < 0 else "left"
    rot = 180 if dx < 0 else 0
    if dy:                       # vertical stub
        rot, just = (90, "left") if dy < 0 else (270, "left")
    graph.append(f'\n  (label "{name}" (at {ex} {ey} {rot})'
                 f' (effects (font (size 1.27 1.27)) (justify {just} bottom))'
                 f' (uuid "{uid()}"))')

def nc(part, pin):
    p = part.pin(pin)
    graph.append(f'\n  (no_connect (at {p[0]} {p[1]}) (uuid "{uid()}"))')

def power(sym, part, pin):
    """attach a power symbol (its pin 1 sits at its own origin offset)"""
    p = part.pin(pin)
    libid = f"power:{sym}"
    px, py, _ = PINS[libid]["1"]
    P = Part(libid, f"#PWR{len(parts):03d}", sym,
             round(p[0] - px, 2), round(p[1] + py, 2))
    return P

def text(s, x, y, size=1.5):
    graph.append(f'\n  (text "{esc(s)}" (exclude_from_sim no) (at {x} {y} 0)'
                 f' (effects (font (size {size} {size})) (justify left bottom))'
                 f' (uuid "{uid()}"))')

def rpart(ref, val, x, y, p1net=None, p2net=None, fp="Resistor_SMD:R_0603_1608Metric"):
    P = Part("Device:R", ref, val, x, y, fp)
    if p1net: net(P, 1, p1net)
    if p2net: net(P, 2, p2net)
    return P

def cpart(ref, val, x, y, p1net=None, p2gnd=True, p2net=None,
          fp="Capacitor_SMD:C_0603_1608Metric"):
    P = Part("Device:C", ref, val, x, y, fp)
    if p1net: net(P, 1, p1net)
    if p2net: net(P, 2, p2net)
    elif p2gnd: power("GND", P, 2)
    return P

# ================================================================ AFE
U1 = Part("Battery_Management:BQ76930DBT", "U1", "BQ76930DBT (3.3V REGOUT variant)",
          140, 140, "Package_SO:TSSOP-30_4.4x7.8mm_P0.5mm")

# cell-sense nets: J1 pins 1..7 = B0..B6 (B0 = BATT-)
J1 = Part("Connector_Generic:Conn_01x07", "J1", "Cell taps B0..B6",
          40, 140, "Connector_PinHeader_2.54mm:PinHeader_1x07_P2.54mm_Vertical")
for k in range(1, 7):
    net(J1, k + 1, f"B{k}")
power("GND", J1, 1)            # B0 = BATT- = board GND (net name GND)

# input filters: used inputs get 100R series + 1uF to the cell below
# 6S on BQ76930 (per SLUSBK2 cell-connection table -- REVIEW note below):
#   group A: cells 1..3 on VC0..VC3, VC4=VC5=VC3
#   group B: cells 4..6 on VC5B,VC6..VC8, VC9=VC10=VC8, VC5X=VC5B
fil = [("RF0", "GND", "VC0F"), ("RF1", "B1", "VC1F"), ("RF2", "B2", "VC2F"),
       ("RF3", "B3", "VC3F"), ("RF4", "B3", "VC5BF"), ("RF5", "B4", "VC6F"),
       ("RF6", "B5", "VC7F"), ("RF7", "B6", "VC8F")]
for i, (ref, a, b) in enumerate(fil):
    rpart(ref, "100", 72, 60 + i * 22, a, b)
cf = [("CF1", "VC1F", "VC0F"), ("CF2", "VC2F", "VC1F"), ("CF3", "VC3F", "VC2F"),
      ("CF4", "VC6F", "VC5BF"), ("CF5", "VC7F", "VC6F"), ("CF6", "VC8F", "VC7F")]
for i, (ref, a, b) in enumerate(cf):
    cpart(ref, "1u", 92, 60 + i * 22, a, p2gnd=False, p2net=b)

netmapU1 = {
    "27": "VC0F", "26": "VC1F", "25": "VC2F", "24": "VC3F",
    "23": "VC3F", "22": "VC3F",                     # VC4, VC5 tied
    "21": "VC5BF", "10": "VC5BF",                   # VC5B, VC5X
    "20": "VC6F", "19": "VC7F", "18": "VC8F",
    "17": "VC8F", "16": "VC8F",                     # VC9, VC10 tied
    "15": "BATRC",                                  # BAT via RC
    "9":  "REGSRC",
    "8":  "+3V3REG",
    "4":  "SDA", "5": "SCL", "30": "ALERT",
    "6":  "TS1", "7": "CAP1", "14": "CAP2",
    "1":  "DSG_DRV", "2": "CHG_DRV",
    "28": "SRP", "29": "SRN",
}
for pin, name in netmapU1.items():
    net(U1, pin, name)
power("GND", U1, 3)                                # VSS
for pin in ("11", "12", "13"):                     # NC(CAP2) x2, TS2
    nc(U1, pin)

# AFE support parts
rpart("R1", "100", 180, 52, "B6", "BATRC")
cpart("C1", "1u", 196, 52, "BATRC")
rpart("R2", "100", 214, 52, "B6", "REGSRC")
cpart("C2", "1u", 230, 52, "REGSRC")
cpart("C3", "1u", 246, 52, "+3V3REG")
cpart("C4", "1u", 180, 80, "CAP1")
cpart("C5", "1u", 196, 80, "CAP2")
TH1 = Part("Device:Thermistor_NTC", "TH1", "10k B=3435", 214, 84,
           "Resistor_SMD:R_0603_1608Metric")
net(TH1, 1, "TS1")
power("GND", TH1, 2)
cpart("C6", "100n", 230, 84, "TS1")

# REGOUT is the board 3V3 rail
rpart("R3", "0", 262, 52, "+3V3REG", "+3V3",
      fp="Resistor_SMD:R_0603_1608Metric")

def anchor(name, x, y, flag="PWR_FLAG"):
    """a labelled point carrying a power-flag driver for ERC"""
    x, y = snap(x), snap(y)
    wire((x, y), (x + 2.54, y))
    graph.append(f'\n  (label "{name}" (at {x + 2.54} {y} 0)'
                 f' (effects (font (size 1.27 1.27)) (justify left bottom))'
                 f' (uuid "{uid()}"))')
    libid = f"power:{flag}"
    px, py, _ = PINS[libid]["1"]
    Part(libid, f"#FLG{len(parts):03d}", flag,
         round(x - px, 2), round(y + py, 2))

anchor("+3V3", 262, 40)
anchor("GND", 276, 40)
anchor("B6", 290, 40)
anchor("REGSRC", 304, 40)

# ============================================== low-side power path
SH = Part("Device:R_Shunt", "RS1", "1m 3W", 70, 262,
          "Resistor_SMD:R_2512_6332Metric")
net(SH, 1, "GND")              # force, battery side (board GND net)
net(SH, 4, "SRB")              # force, FET side
net(SH, 2, "SRN_K")            # kelvin sense, battery side
net(SH, 3, "SRP_K")            # kelvin sense, FET side
rpart("R5", "100", 96, 262, "SRP_K", "SRP")
rpart("R6", "100", 112, 262, "SRN_K", "SRN")
cpart("C7", "100n", 128, 262, "SRP", p2gnd=False, p2net="SRN")

QD = Part("Device:Q_NMOS", "Q1", "NMOS 40V (DSG)", 90, 300,
          "Package_TO_SOT_SMD:TO-252-2")
QC = Part("Device:Q_NMOS", "Q2", "NMOS 40V (CHG)", 130, 300,
          "Package_TO_SOT_SMD:TO-252-2")
# Q_NMOS pin numbers are the letters G / D / S
net(QD, "S", "SRB")
net(QD, "D", "FETMID")
net(QD, "G", "DSG_G")
net(QC, "D", "FETMID")
net(QC, "S", "PACK_M")
net(QC, "G", "CHG_G")
rpart("R7", "100", 60, 300, "DSG_DRV", "DSG_G")
rpart("R8", "10k", 60, 322, "DSG_G", "SRB")
rpart("R9", "100", 160, 300, "CHG_DRV", "CHG_G")
rpart("R10", "10k", 160, 322, "CHG_G", "PACK_M")

J2 = Part("Connector_Generic:Conn_01x02", "J2", "PACK",
          40, 330, "Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical")
net(J2, 1, "B6")               # PACK+
net(J2, 2, "PACK_M")

# ==================================================== host MCU
U2 = Part("MCU_ST_STM32G0:STM32G0B1C_B-C-E_Tx", "U2", "STM32G0B1CBT6",
          330, 150, "Package_QFP:LQFP-48_7x7mm_P0.5mm")
netmapU2 = {
    "45": "SCL", "46": "SDA",          # PB6 / PB7 = I2C1
    "11": "ALERT",                     # PA0
    "16": "LED",                       # PA5
    "35": "SWDIO", "36": "SWCLK",      # PA13 / PA14
    "10": "NRST",                      # PF2-NRST
}
for pin, name in netmapU2.items():
    net(U2, pin, name)
for pin in ("6", "4"):                 # VDD, VBAT
    power("+3V3", U2, pin)
net(U2, 5, "VREFP")                    # VREF+
power("GND", U2, 7)                    # VSS
used = set(netmapU2) | {"4", "5", "6", "7"}
for pin in PINS["MCU_ST_STM32G0:STM32G0B1C_B-C-E_Tx"]:
    if pin not in used:
        nc(U2, pin)

cpart("C8", "100n", 262, 60, "+3V3")
cpart("C9", "100n", 276, 60, "+3V3")
cpart("C10", "4.7u", 290, 60, "+3V3", fp="Capacitor_SMD:C_0805_2012Metric")
rpart("R11", "0", 306, 60, "+3V3", "VREFP")
cpart("C11", "100n", 320, 60, "VREFP")
cpart("C12", "100n", 262, 84, "NRST")
rpart("R12", "4.7k", 240, 60, "+3V3", "SDA")
rpart("R13", "4.7k", 226, 60, "+3V3", "SCL")

J3 = Part("Connector_Generic:Conn_01x05", "J3", "SWD",
          390, 80, "Connector_PinHeader_2.54mm:PinHeader_1x05_P2.54mm_Vertical")
net(J3, 1, "+3V3_SWD")
rpart("R14", "0", 408, 60, "+3V3", "+3V3_SWD")
net(J3, 2, "SWDIO")
net(J3, 3, "SWCLK")
net(J3, 4, "NRST")
power("GND", J3, 5)

D1 = Part("Device:LED", "D1", "green", 390, 200, "LED_SMD:LED_0603_1608Metric")
rpart("R15", "1k", 372, 200, "LED", "LEDK")
net(D1, 2, "LEDK")
power("GND", D1, 1)

# ------------------------------------------------------------- notes
text("6S BMS -- fabrication-grade schematic (BQ76930 AFE + STM32G0B1 host)", 30, 20, 2.5)
text("Generated by kicad/gen_sch.py from official KiCad symbol libraries, tag 9.0.0.", 30, 26)
text("PART SUBSTITUTION: the behavioural model in design/ is BQ76952-class; the official", 30, 32)
text("library carries only the BQ769x0 family, so this sheet uses the 6S-capable BQ76930.", 30, 36)
text("REVIEW BEFORE FABRICATION: (1) 6-cell group mapping on VC pins and VC5X strap per", 30, 42)
text("SLUSBK2 cell-connection table; (2) REGOUT variant = 3.3 V; (3) TS2 termination if", 30, 46)
text("unused; (4) FET selection + gate network vs pack current; (5) SRP/SRN polarity.", 30, 50)
text("Board GND = BATT- (B0).  PACK- switches through DSG/CHG low-side FETs.", 30, 56)

# ------------------------------------------------------------- write
def title_block():
    return '''
  (title_block (title "6S BMS -- BQ76930 + STM32G0B1 (fabrication)")
    (date "2026-09-30") (rev "A")
    (company "bq76952-virtual-bms-demo evidence package"))'''

with open(OUT, "w") as f:
    f.write(f'(kicad_sch (version 20231120) (generator "gen_sch.py")\n'
            f'  (uuid "{ROOT_UUID}") (paper "A2")')
    f.write(title_block())
    f.write("\n  (lib_symbols")
    for s in SYM.values():
        f.write("\n" + s)
    f.write("\n  )")
    for p in parts:
        f.write(p.emit())
    for g in graph:
        f.write(g)
    f.write(f'\n  (sheet_instances (path "/" (page "1")))\n)\n')

print(f"wrote {OUT}: {len(parts)} symbols, "
      f"{sum(1 for g in graph if '(label' in g)} labels, "
      f"{sum(1 for g in graph if 'no_connect' in g)} no-connects")
