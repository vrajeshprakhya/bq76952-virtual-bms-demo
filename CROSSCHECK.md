# Crosscheck: ngspice (schematic) vs xezim (RNM + firmware + UVM-MS)

Two independent simulations of the same board, on the same numbers.
ngspice solves the Figure-2 circuit as an electrical network; xezim
runs the SV-RNM board with the real firmware and the UVM-MS bench.
Where they meet is the whitepaper's evidence.

Sources: `logs_ngspice/ngspice.log` and `logs_xezim/smoke.log` /
`logs_xezim/regress.log` (search keys given per row).

| Quantity (condition) | ngspice (circuit) | xezim (firmware-visible) | Whitepaper claim supported |
| --- | --- | --- | --- |
| Cell tap, 1 A load, 3.7 V cells, 12 mOhm (OP1 `c1..c6`) | 3.688000 V | firmware reads 3688 mV (`smoke.log`, `scen 1`, `c1=3688`) | IR sag is physical and the RNM matches the network solution exactly |
| Shunt sense, 1 A (OP1 `v(nsh)`) | 1.000 mV = 1000 mA | firmware reads 1002 mA (ADC noise +/-5 mA) | current chain scale (1 mOhm, 1 mV/A) |
| TS pin, 25 C (OP1 `v(tsn)`) | 1.6500 V (mid-rail, R_NTC = 10 k) | firmware reads 25.0 C | NTC divider / ratiometric temperature channel |
| DSG open, 1 A still commanded (OP2) | 0.000 mA, cell tap 3.70000 V | `i_act=0`, cells read unloaded (regress scenarios 5, 7, 8, 12) | protection loop-back: the trip stops the *physical* current and the sag vanishes |
| Load sweep 0..4.2 A (`sweep_load.dat`) | shunt exactly 1 mV/A, tap sag exactly 12 mV/A, linear | two-pass scoreboard prediction matches every random corner to ~1 mV / tens of mA | the linear chain the white-box prediction assumes is the network's own behaviour |
| Trip transient at 4.2 A (`bms_trip.cir`) | 4200 mA at t=4 ms; 0 mA and tap 3.7000 V at t=8 ms | hero sequence: OCD latches, `i_act` 4200 -> 0 mA, recover restores 1 A (regress scenarios 11-13) | the hero claim, shown electrically and at firmware level |

Differences to expect, by design: xezim numbers carry the AFE model's
quantisation and noise (cells +/-1 mV, current +/-5 mA) and the
scenario's gain/offset tolerances; ngspice runs the nominal circuit.
The regression's non-nominal scenarios are covered on the xezim side
by the scoreboard's white-box prediction, whose linear-chain
assumption is what the ngspice sweep independently confirms.
