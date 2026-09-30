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
| Balancing read-droop (`bms_full_board.cir` OP2) | DERIVED: 1.983 mA bleed through 2 x 10 Ohm sense lines -> cell 4 reads 39.68 mV low | RNM parameter VBAL_DROOP = 40 mV; firmware sees it in regress scenario 9 | the balancing artifact is network physics, not a fitted constant |
| I2C wired-AND (`bms_full_board.cir` tran) | SDA = 0.35 uV while either side pulls, 3.30 V released | testbench top resolves `sda = !(pull_m or pull_s)`; every transaction in every log rode it | the pin-level open-drain bus claim |

Differences to expect, by design: xezim numbers carry the AFE model's
quantisation and noise (cells +/-1 mV, current +/-5 mA) and the
scenario's gain/offset tolerances; ngspice runs the nominal circuit.
The regression's non-nominal scenarios are covered on the xezim side
by the scoreboard's white-box prediction, whose linear-chain
assumption is what the ngspice sweep independently confirms.

The fab schematic is ALSO simulated directly: `kicad/run_fab_sim.sh`
exports the SPICE netlist from `bms_6s_fab.kicad_sch` with kicad-cli
and runs it in ngspice against numeric assertions
(`logs_ngspice/fab_sim.log`): cell tap 3.688 V at 1 A, shunt-sense
1.002 mV, DSG-open -> 0 A with sag vanished, CHG-open discharge via
the body diode, and the balancing read-droop DERIVED from the sheet's
own values.  That last one resolves the filter-value divergence this
exercise surfaced: with the fab sheet's datasheet-typical 100R input
filters and an assumed 30R internal balance FET, the BQ76930 bleeds
16.0 mA and the balanced cell reads 0.481 V low (asserted against the
analytic Vcell*30/230) -- the LARGE-droop regime, which is why
BQ769x0 datasheets say not to trust a cell reading while balancing
it.  The xezim RNM's 40 mV parameter models the SMALL-droop regime of
a BQ76952-class part (10R-class sense lines, as in the hand deck
`schematic/bms_full_board.cir`).  Both regimes are now simulated,
each self-consistent, and the difference is a documented part/values
choice rather than silent drift.

Two fidelity notes the full-board circuit adds:
1. While a cell balances, its NEIGHBOURS read ~20 mV HIGH (the bleed
   current through the shared sense line).  The RNM simplifies this
   into the single-cell -40 mV droop; a model upgrade would add the
   +Ibal*RLINE term to the adjacent cells.
2. The kelvin RC filter (100 Ohm / 100 nF) attenuates the injected
   20 kHz ripple to about +/-90 mA at the AFE (`full_board.log`,
   mean 1008 / max 1097 / min 926 mA), where the RNM injects the
   unfiltered +/-200 mA at the summing node -- a conservative
   placement the UVM tolerance is sized for.
