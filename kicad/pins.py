#!/usr/bin/env python3
"""Print the pin tables of the symbols the fab schematic will use,
straight from the fetched official libraries."""
import re, sys

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
                return text[i:j+1]
    raise RuntimeError("unbalanced")

PIN = re.compile(
    r'\(pin\s+(\w+)\s+\w+\s*\(at\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\)\s*'
    r'\(length\s+([\d.]+)\)\s*\(name\s+"([^"]+)"', re.S)

def pins(sym_text):
    out = []
    for m in PIN.finditer(sym_text):
        elec, x, y, ang, ln, name = m.groups()
        num = re.search(r'\(number\s+"([^"]+)"', sym_text[m.start():m.start()+600]).group(1)
        out.append((int(num) if num.isdigit() else num, name, elec, float(x), float(y), int(ang)))
    return sorted(out, key=lambda t: (isinstance(t[0], str), t[0]))

for lib, name in [("Device", "Q_NMOS"), ("Device", "R_Shunt"),
                  ("Device", "Thermistor_NTC"), ("Device", "LED"),
                  ("power", "GND"), ("power", "+3V3"), ("power", "PWR_FLAG")]:
    text = open(f"libs/{lib}.kicad_sym").read()
    b = block(text, name)
    print(f"===== {name} ({len(b)} bytes) =====")
    ext = re.search(r'\(extends "([^"]+)"\)', b)
    if ext:
        print("EXTENDS", ext.group(1))
    for p in pins(b):
        print(f"  {p[0]:>4}  {p[1]:<12} {p[2]:<15} at({p[3]},{p[4]}) ang{p[5]}")

dev = open("libs/Device.kicad_sym").read()
print("===== NMOS symbols available =====")
for m in sorted(set(re.findall(r'\(symbol "(Q_NMOS[A-Za-z0-9_,]*)"', dev))):
    print(" ", m)
for n in ["Thermistor_NTC", "Battery_Cell", "R", "C", "R_Shunt"]:
    try:
        b = block(dev, n)
        ext = re.search(r'\(extends "([^"]+)"\)', b)
        print(n, "extends", ext.group(1) if ext else "-", f"({len(b)}b)")
    except ValueError:
        print(n, "NOT FOUND")
