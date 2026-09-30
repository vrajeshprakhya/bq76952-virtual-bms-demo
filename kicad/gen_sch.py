#!/usr/bin/env python3
"""Generate bms_6s_fab.kicad_sch -- fabrication-grade schematic of the
6S BMS board (BQ76930 AFE + STM32G0B1 host), fully wired: every
connection is drawn copper (orthogonal wires + junction dots), not
label-glue.  Each functional net additionally carries ONE small name
label riding on its wire, which is what keeps check_netlist.py's
golden table addressable by name.

Layout scheme: each IC has a fan-out corridor beside it (one vertical
"slot" per net at a unique x), so exits never overlap; passives are
fitted onto wires by solving their position from the symbol's own pin
offsets.  Verified by verify_sch.sh: ERC + exported-netlist golden
compare after every change.

Symbols come verbatim from the OFFICIAL KiCad libraries (installed
10.0.6 preferred, tag 9.0.0 fetch via fetch_libs.sh as fallback).
Part substitution: the official library has no BQ76952; the 6S-capable
BQ76930 is used (stated on the sheet).
"""
import re, uuid, os

# ------------------------------------------------------------ library
_INSTALLED = "/mnt/c/Users/vraje/AppData/Local/Programs/KiCad/10.0/share/kicad/symbols"
LIBDIR = _INSTALLED if os.path.isdir(_INSTALLED) else "libs"
OUT = "bms_6s_fab.kicad_sch"
ROOT_UUID = "a0b1c2d3-0001-4000-8000-000000000001"
PROJ = "bms_6s_fab"
print(f"symbol source: {LIBDIR}")

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
SYM, PINS = {}, {}
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

G = 1.27
def snap(v):
    return round(round(v / G) * G, 2)

# design-space extents are ~x[4,252], y[14,242]; A2 is 594 x 420.
# This offset, applied only at emission, centres the drawing on the
# sheet (multiples of 1.27 so everything stays on-grid).
OX, OY = 165.1, 81.28
def ox(v):
    return round(v + OX, 2)
def oy(v):
    return round(v + OY, 2)

parts, graph = [], []
def esc(s):
    return s.replace('"', '\\"')

class Part:
    def __init__(self, libid, ref, value, x, y, rot=0, footprint="", label_dy=-4,
                 spice=None, spins=None):
        self.libid, self.ref, self.value, self.rot = libid, ref, value, rot
        self.x, self.y, self.fp = snap(x), snap(y), footprint
        self.ldy = label_dy
        self.spice = spice          # subckt name -> exported as X-card
        self.spins = spins          # explicit Sim.Pins mapping
        parts.append(self)

    def pin(self, num):
        px, py, _ = PINS[self.libid][str(num)]
        r = self.rot % 360
        if r == 0:
            dx, dy = px, -py
        elif r == 90:
            dx, dy = -py, -px
        elif r == 180:
            dx, dy = -px, py
        else:
            dx, dy = py, px
        return (round(self.x + dx, 2), round(self.y + dy, 2))

    def sim_props(self):
        """SPICE binding: every smart/discrete part is a SUBCKT whose
        definition lives in bms_fab_models.lib, so the kicad-cli SPICE
        export of THIS sheet is directly simulatable."""
        if not self.spice:
            return ""
        out = ""
        kv = [("Sim.Device", "SUBCKT"), ("Sim.Name", self.spice),
              ("Sim.Library", "${KIPRJMOD}/bms_fab_models.lib")]
        if self.spins:
            kv.append(("Sim.Pins", self.spins))
        for k, v in kv:
            out += (f'\n    (property "{k}" "{v}" (at {ox(self.x)} {oy(self.y)} 0)'
                    f' (effects (font (size 1.27 1.27)) (hide yes)))')
        return out

    def emit(self):
        pins = "".join(f'\n    (pin "{n}" (uuid "{uid()}"))'
                       for n in PINS[self.libid])
        hid = " (hide yes)" if self.ref.startswith("#") else ""
        big = self.ref in ("U1", "U2")
        ry = self.y - (34 if self.ref == "U1" else 56) if big else self.y + self.ldy
        vy = ry + 4 if big else self.y - self.ldy
        rx = self.x - 10 if big else self.x + 2.2
        return f'''
  (symbol (lib_id "{self.libid}") (at {ox(self.x)} {oy(self.y)} {self.rot}) (unit 1)
    (exclude_from_sim no) (in_bom yes) (on_board yes) (dnp no)
    (uuid "{uid()}")
    (property "Reference" "{self.ref}" (at {ox(rx)} {oy(ry)} 0)
      (effects (font (size 1.27 1.27)) (justify left){hid}))
    (property "Value" "{esc(self.value)}" (at {ox(rx)} {oy(vy)} 0)
      (effects (font (size 1.27 1.27)) (justify left){hid}))
    (property "Footprint" "{self.fp}" (at {ox(self.x)} {oy(self.y)} 0)
      (effects (font (size 1.27 1.27)) (hide yes)))
    (property "Datasheet" "" (at {ox(self.x)} {oy(self.y)} 0)
      (effects (font (size 1.27 1.27)) (hide yes))){self.sim_props()}{pins}
    (instances (project "{PROJ}"
      (path "/{ROOT_UUID}" (reference "{self.ref}") (unit 1)))))'''

def wseg(a, b):
    if a == b:
        return
    assert a[0] == b[0] or a[1] == b[1], f"diagonal {a}->{b}"
    graph.append(f'\n  (wire (pts (xy {ox(a[0])} {oy(a[1])})'
                 f' (xy {ox(b[0])} {oy(b[1])}))'
                 f' (stroke (width 0) (type default)) (uuid "{uid()}"))')

def route(*pts):
    """orthogonal polyline through the given points"""
    for a, b in zip(pts, pts[1:]):
        wseg(a, b)

def jn(x, y):
    graph.append(f'\n  (junction (at {ox(x)} {oy(y)}) (diameter 0)'
                 f' (color 0 0 0 0) (uuid "{uid()}"))')

def tag(name, x, y, rot=0):
    """net NAME riding on an existing wire point"""
    graph.append(f'\n  (label "{name}" (at {ox(x)} {oy(y)} {rot})'
                 f' (effects (font (size 1.27 1.27)) (justify left bottom))'
                 f' (uuid "{uid()}"))')

def nc(part, pinno):
    p = part.pin(pinno)
    graph.append(f'\n  (no_connect (at {ox(p[0])} {oy(p[1])})'
                 f' (uuid "{uid()}"))')

def pwr(sym, x, y):
    libid = f"power:{sym}"
    px, py, _ = PINS[libid]["1"]
    Part(libid, f"#PWR{len(parts):03d}", sym,
         round(x - px, 2), round(y + py, 2))

def gnd(x, y, drop=0):
    if drop:
        wseg((x, y), (x, y + drop))
    pwr("GND", x, y + drop)

def v3(x, y, rise=0):
    if rise:
        wseg((x, y), (x, y - rise))
    pwr("+3V3", x, y - rise)

def text(s, x, y, size=1.5):
    graph.append(f'\n  (text "{esc(s)}" (exclude_from_sim no)'
                 f' (at {ox(x)} {oy(y)} 0)'
                 f' (effects (font (size {size} {size})) (justify left bottom))'
                 f' (uuid "{uid()}"))')

def R(ref, val, x, y, rot=0):
    return Part("Device:R", ref, val, x, y, rot,
                "Resistor_SMD:R_0603_1608Metric")

def C(ref, val, x, y, rot=0, fp="Capacitor_SMD:C_0603_1608Metric"):
    return Part("Device:C", ref, val, x, y, rot, fp)

# =====================================================================
#  PLACEMENT (units of 2.54 where convenient; all snapped)
# =====================================================================
U1 = Part("Battery_Management:BQ76930DBT", "U1",
          "BQ76930DBT (3.3V REGOUT)", 152.4, 121.92, 0,
          "Package_SO:TSSOP-30_4.4x7.8mm_P0.5mm", spice="BQ76930_BEH")
U2 = Part("MCU_ST_STM32G0:STM32G0B1C_B-C-E_Tx", "U2", "STM32G0B1CBT6",
          55.88, 121.92, 0, "Package_QFP:LQFP-48_7x7mm_P0.5mm",
          spice="STM32_STUB")

U1R, U1L = 165.1, 139.7
def xr(s):            # right-corridor slot x
    return round(U1R + G * s, 2)
def xl(s):            # left-corridor slot x
    return round(U1L - G * s, 2)

# ---------------- right side: cell rows --------------------------
ROWX0 = 181.61        # rows begin right of the corridor
FILX = 198.12         # horizontal filter resistors
CFX1, CFX2 = 184.15, 187.96
TRK = {"B1": 208.28, "B2": 210.82, "B3": 213.36,
       "B4": 215.9, "B5": 218.44, "B6": 220.98, "GNDT": 223.52}
ROW = {"VC8F": 66.04, "VC7F": 76.2, "VC6F": 86.36, "VC5BF": 96.52,
       "VC3F": 106.68, "VC2F": 116.84, "VC1F": 127.0, "VC0F": 137.16}

def u1p(n):
    return U1.pin(n)

# tie bars on the corridor's first slot
for pins_ in (("16", "17", "18"), ("22", "23", "24")):
    ys = [u1p(p)[1] for p in pins_]
    for p in pins_:
        route(u1p(p), (xr(1), u1p(p)[1]))
    wseg((xr(1), min(ys)), (xr(1), max(ys)))
    jn(xr(1), ys[1])

# staircases: (net, U1 exit pin, slot)
STAIR = [("VC8F", "17", 2), ("VC7F", "19", 3), ("VC6F", "20", 4),
         ("VC5BF", "21", 5), ("VC3F", "23", 6), ("VC2F", "25", 7),
         ("VC1F", "26", 8)]
for name, pin, s in STAIR:
    py = u1p(pin)[1]
    start = (xr(1), py) if pin in ("17", "23") else u1p(pin)
    route(start, (xr(s), py), (xr(s), ROW[name]), (ROWX0, ROW[name]))
# VC0F: pin 27 y == its row -> straight out
route(u1p("27"), (ROWX0, ROW["VC0F"]))
# rows to the filters
for name, y in ROW.items():
    wseg((ROWX0, y), (FILX - 3.81, y))
    tag(name, snap(ROWX0 + 1.27), y)

# filters (horizontal R, rot 90): left pin on row, right pin to trunk
FIL = [("RF7", "VC8F", "B6"), ("RF6", "VC7F", "B5"), ("RF5", "VC6F", "B4"),
       ("RF4", "VC5BF", "B3"), ("RF3", "VC3F", "B3"), ("RF2", "VC2F", "B2"),
       ("RF1", "VC1F", "B1"), ("RF0", "VC0F", "GNDT")]
for ref, row, trunk in FIL:
    y = ROW[row]
    r = R(ref, "100", FILX, y, 90)
    wseg(r.pin(2), (TRK[trunk], y))
    jn(TRK[trunk], y) if trunk != "GNDT" else None
# differential input caps between adjacent rows
CF = [("CF6", "VC8F", "VC7F", CFX1), ("CF5", "VC7F", "VC6F", CFX2),
      ("CF4", "VC6F", "VC5BF", CFX1), ("CF3", "VC3F", "VC2F", CFX2),
      ("CF2", "VC2F", "VC1F", CFX1), ("CF1", "VC1F", "VC0F", CFX2)]
for ref, up, dn, x in CF:
    yu, yd = ROW[up], ROW[dn]
    c = C(ref, "1u", x, (yu + yd) / 2)
    route((x, yu), c.pin(1))
    route(c.pin(2), (x, yd))
    jn(x, yu)
    jn(x, yd)

# trunks down to J1 (placed below the row zone)
J1 = Part("Connector_Generic:Conn_01x07", "J1", "Cell taps", 243.84, 175.26, 0,
          "Connector_PinHeader_2.54mm:PinHeader_1x07_P2.54mm_Vertical",
          spice="PACK6S")     # the virtual 6S pack plugs in here
J1E = {n: J1.pin(n) for n in map(str, range(1, 8))}
ORDER = ["GNDT", "B1", "B2", "B3", "B4", "B5", "B6"]
for i, trunk in enumerate(ORDER):
    jpin = J1E[str(i + 1)]
    x = TRK[trunk]
    top = {"GNDT": ROW["VC0F"], "B1": ROW["VC1F"], "B2": ROW["VC2F"],
           "B3": ROW["VC5BF"], "B4": ROW["VC6F"], "B5": ROW["VC7F"],
           "B6": 58.42}[trunk]
    route((x, top), (x, jpin[1]), jpin)
    if trunk == "B3":          # second row joins the B3 trunk
        jn(x, ROW["VC3F"])
    if trunk.startswith("B"):
        # staggered down the trunk, clear of every crossing wire
        tag(trunk, x, snap(149.86 + 2.54 * (i - 1)))
gnd(J1E["1"][0] - 5.08, J1E["1"][1], drop=0)  # placed via trunk below:
# (GND trunk gets its symbol at the bottom instead)
parts.pop()                                    # drop that misplaced GND
gnd(TRK["GNDT"], J1E["1"][1], drop=5.08)
jn(TRK["GNDT"], J1E["1"][1])

# ---------------- top power block --------------------------------
Y3REG, YGND, YRSRC, YBATR, YB6 = 30.48, 38.1, 45.72, 50.8, 58.42
# rails
wseg((xr(10), Y3REG), (231.14, Y3REG))
tag("+3V3REG", snap(xr(10) + 2.54), Y3REG)
wseg((189.23, YGND), (240.03, YGND))
gnd(240.03, YGND, drop=0)
wseg((152.4, YRSRC), (204.47, YRSRC))
tag("REGSRC", 154.94, YRSRC)
wseg((xr(9), YBATR), (196.85, YBATR))
tag("BATRC", snap(xr(9) + 2.54), YBATR)
wseg((196.85, YB6), (TRK["B6"], YB6))
tag("B6", 198.12, YB6)
jn(TRK["B6"], YB6)
# REGOUT -> +3V3REG (slot 10 up)
route(u1p("8"), (xr(10), u1p("8")[1]), (xr(10), Y3REG))
# BAT -> BATRC (slot 9 up)
route(u1p("15"), (xr(9), u1p("15")[1]), (xr(9), YBATR))
# REGSRC (top pin) up then right
route(u1p("9"), (152.4, YRSRC))
# R1 BATRC->B6 ; C1 BATRC->GND
r1 = R("R1", "100", 196.85, YBATR + 3.81, 0)
wseg(r1.pin(2), (196.85, YB6))
c1 = C("C1", "1u", 191.77, YBATR - 3.81)
route((191.77, YGND), c1.pin(1))
wseg(c1.pin(2), (191.77, YBATR))
jn(191.77, YGND)
jn(191.77, YBATR)
# R2 REGSRC->B6 ; C2 REGSRC->GND
r2 = R("R2", "100", 204.47, YRSRC + 3.81, 0)
route(r2.pin(2), (204.47, YB6))
jn(204.47, YB6)
c2 = C("C2", "1u", 189.23, YRSRC - 3.81)
route((189.23, YGND), c2.pin(1))
wseg(c2.pin(2), (189.23, YRSRC))
jn(189.23, YGND)
jn(189.23, YRSRC)
# C3 +3V3REG->GND ; R3 0R +3V3REG->+3V3
c3 = C("C3", "1u", 203.2, Y3REG + 3.81)
wseg((203.2, Y3REG), c3.pin(1))
route(c3.pin(2), (203.2, YGND))
jn(203.2, Y3REG)
jn(203.2, YGND)
r3 = R("R3", "0", 231.14 + 3.81, Y3REG, 90)
v3(r3.pin(2)[0], r3.pin(2)[1], rise=2.54)

# ---------------- U1 left side -----------------------------------
# I2C to the MCU (with pull-ups riding the runs)
sda_y, scl_y = u1p("4")[1], u1p("5")[1]
pb7, pb6 = U2.pin("46"), U2.pin("45")
route(u1p("4"), (xl(9), sda_y), (xl(9), pb7[1]), pb7)
tag("SDA", 110.49, pb7[1])
route(u1p("5"), (xl(8), scl_y), (xl(8), pb6[1]), pb6)
tag("SCL", 110.49, pb6[1])
r12 = R("R12", "4.7k", 100.33, pb7[1] - 3.81)
wseg(r12.pin(2), (100.33, pb7[1]))
jn(100.33, pb7[1])
v3(*r12.pin(1), rise=2.54)
r13 = R("R13", "4.7k", 95.25, pb6[1] - 3.81)
wseg(r13.pin(2), (95.25, pb6[1]))
jn(95.25, pb6[1])
v3(*r13.pin(1), rise=2.54)
# ALERT
pa0 = U2.pin("11")
route(u1p("30"), (xl(7), u1p("30")[1]), (xl(7), pa0[1]), pa0)
tag("ALERT", 110.49, pa0[1])
# CAP1 / CAP2
c4 = C("C4", "1u", xl(4), u1p("7")[1] + 6.35)
route(u1p("7"), (xl(4), u1p("7")[1]), c4.pin(1))
gnd(*c4.pin(2), drop=1.27)
tag("CAP1", snap(xl(4) + 1.27), u1p("7")[1])
c5 = C("C5", "1u", xl(5), u1p("14")[1] + 6.35)
route(u1p("14"), (xl(5), u1p("14")[1]), c5.pin(1))
gnd(*c5.pin(2), drop=1.27)
tag("CAP2", snap(xl(5) + 1.27), u1p("14")[1])
# TS1: NTC + C6
ts1 = u1p("6")
th1 = Part("Device:Thermistor_NTC", "TH1", "10k B=3435", xl(3), ts1[1] + 6.35,
           0, "Resistor_SMD:R_0603_1608Metric", spice="NTC10K")
route(ts1, (xl(3), ts1[1]), th1.pin(1))
gnd(*th1.pin(2), drop=1.27)
tag("TS1", snap(xl(3) + 1.27), ts1[1])
c6 = C("C6", "100n", xl(3) - 6.35, ts1[1] + 6.35)
wseg((xl(3) - 6.35, ts1[1]), (xl(3), ts1[1]))
jn(xl(3), ts1[1])
wseg((xl(3) - 6.35, ts1[1]), c6.pin(1))
gnd(*c6.pin(2), drop=1.27)
# VC5X: under-route to the VC5BF row
v5x = u1p("10")
UNDY = 157.48
UPX = 190.5
route(v5x, (xl(6), v5x[1]), (xl(6), UNDY), (UPX, UNDY),
      (UPX, ROW["VC5BF"]))
jn(UPX, ROW["VC5BF"])
# DSG / CHG drives head down to the FET zone
dsg, chg = u1p("1"), u1p("2")
DSGY, CHGY = 215.9, 218.44
wseg(dsg, (xl(1), dsg[1]))
wseg(chg, (xl(2), chg[1]))
tag("DSG", xl(1), snap(dsg[1] + 5.08))
tag("CHG", xl(2), snap(chg[1] + 5.08))
# VSS
gnd(*u1p("3"), drop=2.54)
# NC pins
for p in ("11", "12", "13"):
    nc(U1, p)

# ---------------- shunt + FETs + PACK ----------------------------
RS1 = Part("Device:R_Shunt", "RS1", "1m 3W", 152.4, 205.74, 0,
           "Resistor_SMD:R_2512_6332Metric", spice="SHUNT_1M")
gnd(*RS1.pin("1"), drop=-0)
pwr("PWR_FLAG", *RS1.pin("1"))
# kelvin: SRP senses the FET-side terminal (RS1.3), SRN the battery
# side (RS1.2) -- discharge current enters at pin 4, so pin 3 is the
# positive sense.  (v1 had them crossed; caught by check_netlist.py.)
s2, s3 = RS1.pin("2"), RS1.pin("3")
r5 = R("R5", "100", 163.83, s3[1], 90)          # SRP row = pin3's y
wseg(s3, r5.pin(1))
tag("SRP_K", 157.48, s3[1])
r6y = 198.12                                     # SRN row above
r6 = R("R6", "100", 163.83, r6y, 90)
route(s2, (158.75, s2[1]), (158.75, r6y), r6.pin(1))
tag("SRN_K", 157.48, s2[1])
srp, srn = u1p("28"), u1p("29")
route(r5.pin(2), (xr(11), s3[1]), (xr(11), srp[1]), srp)
route(r6.pin(2), (xr(12), r6y), (xr(12), srn[1]), srn)
tag("SRP", xr(11), snap(srp[1] + 20.32))
tag("SRN", xr(12), snap(srn[1] + 22.86))
c7 = C("C7", "100n", 171.45, (s3[1] + r6y) / 2)
route((171.45, r6y), c7.pin(1))
route(c7.pin(2), (171.45, s3[1]))
jn(171.45, r6y)
jn(171.45, s3[1])
# power path: RS1 bottom -> Q1(DSG) -> Q2(CHG) -> PACK-
# gate feeds approach from the LEFT via a bypass row, so the series
# gate resistors sit in-line and nothing overlaps the feed wire
Q1 = Part("Device:Q_NMOS", "Q1", "NMOS 40V", 137.16, DSGY, 0,
          "Package_TO_SOT_SMD:TO-252-2", spice="NFET40", spins="D=1 G=2 S=3")
Q2 = Part("Device:Q_NMOS", "Q2", "NMOS 40V", 114.3, DSGY, 0,
          "Package_TO_SOT_SMD:TO-252-2", spice="NFET40", spins="D=1 G=2 S=3")
SRBY = 228.6
q1s, q1d, q1g = Q1.pin("S"), Q1.pin("D"), Q1.pin("G")
q2s, q2d, q2g = Q2.pin("S"), Q2.pin("D"), Q2.pin("G")
# SRB: shunt bottom across to under Q1, extended left to catch R8
route(RS1.pin("4"), (152.4, SRBY))
wseg((129.54, SRBY), (152.4, SRBY))
route((q1s[0], SRBY), q1s)
jn(q1s[0], SRBY)
tag("SRB", 144.78, SRBY)
# FETMID: drains joined above the pair
FMY = 203.2
route(q1d, (q1d[0], FMY), (q2d[0], FMY), q2d)
tag("FETMID", snap(q2d[0] + 3.81), FMY)
# DSG gate: bypass row at y=208.28, then in-line R7 into the gate
BYP1 = 208.28
route((xl(1), DSGY), (xl(1), BYP1)) if False else None
route((xl(1), dsg[1]), (xl(1), BYP1))
r7 = R("R7", "100", 124.46, DSGY, 90)
route((xl(1), BYP1), (115.57, BYP1), (115.57, DSGY), r7.pin(1))
wseg(r7.pin(2), q1g)
r8 = R("R8", "10k", 129.54, 219.71)
wseg((129.54, DSGY), r8.pin(1))
jn(129.54, DSGY)
route(r8.pin(2), (129.54, SRBY))
tag("DSG_G", 130.5, DSGY)
# CHG gate: bypass row at y=213.36, in-line R9 into Q2's gate
BYP2 = 213.36
route((xl(2), chg[1]), (xl(2), BYP2))
r9 = R("R9", "100", 101.6, DSGY, 90)
route((xl(2), BYP2), (93.98, BYP2), (93.98, DSGY), r9.pin(1))
wseg(r9.pin(2), q2g)
r10 = R("R10", "10k", 106.68, 219.71)
wseg((106.68, DSGY), r10.pin(1))
jn(106.68, DSGY)
PMY = 233.68
route(r10.pin(2), (106.68, PMY))
tag("CHG_G", 107.6, DSGY)
# PACK- run and J2
J2 = Part("Connector_Generic:Conn_01x02", "J2", "PACK", 233.68, 231.14, 0,
          "Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical",
          spice="LOADBOX")    # the commanded load plugs in here
wseg((106.68, PMY), (J2.pin("2")[0] - 5.08, PMY))
wseg((J2.pin("2")[0] - 5.08, PMY), J2.pin("2"))
route(q2s, (q2s[0], PMY))
jn(q2s[0], PMY)
tag("PACK_M", snap(q2s[0] + 5.08), PMY)
# PACK+ = B6: from the B6 trunk down
route((TRK["B6"], J1E["7"][1]), (TRK["B6"], J2.pin("1")[1]), J2.pin("1"))
jn(TRK["B6"], J1E["7"][1])
pwr("PWR_FLAG", TRK["B6"], 55.88)
wseg((TRK["B6"], 55.88), (TRK["B6"], YB6))

# ---------------- MCU support ------------------------------------
# supply pins
vbat, vdd = U2.pin("4"), U2.pin("6")
wseg(vbat, (vbat[0], vbat[1] - 2.54))
wseg(vdd, (vdd[0], vdd[1] - 2.54))
wseg((vbat[0], vbat[1] - 2.54), (vdd[0], vdd[1] - 2.54))
v3(vbat[0], vbat[1] - 2.54, rise=0)
gnd(*U2.pin("7"), drop=2.54)
# decoupling row left of U2, on a +3V3/GND ladder
DECX = [10.16, 15.24, 20.32]
DEC = [("C8", "100n"), ("C9", "100n"), ("C10", "4.7u")]
for (ref, val), x in zip(DEC, DECX):
    c = C(ref, val, x, 66.04,
          fp="Capacitor_SMD:C_0805_2012Metric" if ref == "C10"
          else "Capacitor_SMD:C_0603_1608Metric")
    v3(*c.pin(1), rise=1.27)
    gnd(*c.pin(2), drop=1.27)
# VREF+ via R11, filtered by C11
vref = U2.pin("5")
r11 = R("R11", "0", 5.08, vref[1] - 6.35)
route(vref, (5.08, vref[1]), r11.pin(2))
v3(*r11.pin(1), rise=1.27)
c11 = C("C11", "100n", 10.16, vref[1] + 3.81)
wseg((10.16, vref[1]), c11.pin(1))
jn(10.16, vref[1])
gnd(*c11.pin(2), drop=1.27)
tag("VREFP", 16.51, vref[1])
# NRST: cap + SWD
nrst = U2.pin("10")
c12 = C("C12", "100n", 13.97, nrst[1] + 6.35)
route(nrst, (13.97, nrst[1]), c12.pin(1))
gnd(*c12.pin(2), drop=1.27)
tag("NRST", 16.51, nrst[1])
J3 = Part("Connector_Generic:Conn_01x05", "J3", "SWD", 113.03, 180.34, 0,
          "Connector_PinHeader_2.54mm:PinHeader_1x05_P2.54mm_Vertical",
          spice="SWD_OPEN")
j3 = {n: J3.pin(n) for n in "12345"}
# +3V3 via R14
r14 = R("R14", "0", 97.79, j3["1"][1], 90)
wseg(r14.pin(2), j3["1"])
tag("+3V3_SWD", 104.14, j3["1"][1])
v3(*r14.pin(1), rise=2.54)
# SWDIO / SWCLK from PA13 / PA14
pa13, pa14 = U2.pin("35"), U2.pin("36")
route(pa13, (92.71, pa13[1]), (92.71, j3["2"][1]), j3["2"])
route(pa14, (90.17, pa14[1]), (90.17, j3["3"][1]), j3["3"])
tag("SWDIO", 95.25, j3["2"][1])
tag("SWCLK", 92.71, j3["3"][1])
# NRST down to J3.4
jn(13.97, nrst[1])
NRX = 8.89
route((13.97, nrst[1]), (NRX, nrst[1]), (NRX, 195.58),
      (j3["4"][0] - 5.08, 195.58), (j3["4"][0] - 5.08, j3["4"][1]), j3["4"])
gnd(*j3["5"], drop=2.54)
# LED on PA5 (D1 rotated so the anode faces the resistor)
pa5 = U2.pin("16")
r15 = R("R15", "1k", 105.41, pa5[1], 90)
wseg(pa5, r15.pin(1))
d1 = Part("Device:LED", "D1", "green", 116.84, pa5[1], 180,
          "LED_SMD:LED_0603_1608Metric", spice="LED_G")
wseg(r15.pin(2), d1.pin("2"))
tag("LED", 96.52, pa5[1])
tag("LEDK", 110.49, pa5[1])
gnd(*d1.pin("1"), drop=2.54)
# unused MCU pins
used2 = {"4", "5", "6", "7", "10", "11", "16", "35", "36", "45", "46"}
for p in PINS["MCU_ST_STM32G0:STM32G0B1C_B-C-E_Tx"]:
    if p not in used2:
        nc(U2, p)

# power flags for ERC on driven-through-R nets (each placed on an
# existing junction or wire endpoint so the pin really connects)
pwr("PWR_FLAG", 189.23, YRSRC)          # on C2's REGSRC junction
pwr("PWR_FLAG", 20.32, 66.04 - 3.81 - 1.27)   # +3V3 at C10's riser

# ---------------- notes ------------------------------------------
text("6S BMS -- fabrication-grade schematic (BQ76930 AFE + STM32G0B1 host), fully wired", 12, 16, 2.2)
text("PART SUBSTITUTION: behavioural model is BQ76952-class; official lib carries BQ769x0 only -> 6S-capable BQ76930.", 12, 21)
text("REVIEW BEFORE FABRICATION: cell-group mapping + VC5X strap (SLUSBK2), REGOUT variant 3.3 V, TS2 termination,", 12, 25)
text("FET selection + gate network vs pack current, SRP/SRN polarity.  Board GND = BATT- (J1.1).", 12, 29)
text("Verification: kicad/verify_sch.sh = ERC + netlist export + golden connectivity compare (43 nets).", 12, 33)

# ------------------------------------------------------------- write
with open(OUT, "w") as f:
    f.write(f'(kicad_sch (version 20231120) (generator "gen_sch.py")\n'
            f'  (uuid "{ROOT_UUID}") (paper "A2")')
    f.write('''
  (title_block (title "6S BMS -- BQ76930 + STM32G0B1 (fabrication)")
    (date "2026-09-30") (rev "B")
    (company "bq76952-virtual-bms-demo evidence package"))''')
    f.write("\n  (lib_symbols")
    for s in SYM.values():
        f.write("\n" + s)
    f.write("\n  )")
    for p in parts:
        f.write(p.emit())
    for g in graph:
        f.write(g)
    f.write('\n  (sheet_instances (path "/" (page "1")))\n)\n')

nw = sum(1 for g in graph if "(wire" in g)
print(f"wrote {OUT}: {len(parts)} symbols, {nw} wire segments, "
      f"{sum(1 for g in graph if '(junction' in g)} junctions, "
      f"{sum(1 for g in graph if '(label' in g)} name tags, "
      f"{sum(1 for g in graph if 'no_connect' in g)} no-connects")
