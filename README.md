# bq_vboard_evidence — everything behind the whitepaper, in one place

Self-contained evidence package for
`whitepaper/whitepaper.pdf` ("Co-Verifying BMS Firmware Against a
Virtual Board").  Every claim in the paper traces to a file here, and
every log was produced by the sources in this directory.

```
whitepaper/    whitepaper.tex + .pdf (the document being supported)
design/        the complete simulated design, verbatim:
                 rnm/   SV-RNM board: pack, BQ76952-class AFE
                        (I2C slave + protection engine), ripple
                 fw/    the real C firmware (bit-banged I2C master)
                 mcu/   DPI tick shim (Renode swap-in point)
                 tb/    UVM-MS: proxy, bridge, env, tests
                 run.sh / compile.f
schematic/     the board as SPICE + a drawn schematic sheet:
                 bms_core.inc        one-path netlist (Fig. 2 of the
                                     whitepaper)
                 bms_op.cir          operating points + 0..4.2 A sweep
                 bms_trip.cir        transient DSG trip at 5 ms
                 bms_full_board.cir  FULL board: all 7 sense lines with
                                     filters, per-cell balancing
                                     bleeders, DSG+CHG FETs with body
                                     diodes, charger stub, shunt kelvin
                                     with EMI injection, I2C pull-ups
                                     with open-drain pulls both ends,
                                     NTC -- simulated
                 bms_full_board.tex/.pdf  the drawn full-board
                                     schematic sheet (1:1 with the
                                     netlist)
                 run_ngspice.sh
kicad/         fabrication-grade KiCad schematic (ERC-clean):
                 bms_6s_fab.kicad_sch  the sheet -- BQ76930 AFE +
                                       STM32G0B1CBT6 host, cell-input
                                       filters, low-side DSG/CHG FETs,
                                       kelvin shunt, NTC, I2C pull-ups,
                                       SWD, decoupling; real footprints
                 bms_6s_fab.pdf        kicad-cli export
                 bms_6s_fab_erc.rpt    ERC report: 0 violations
                 gen_sch.py            the generator (symbols embedded
                                       from the official KiCad libs)
                 fetch_libs.sh         library provenance (tag 9.0.0
                                       fallback; installed KiCad
                                       10.0.6 libs preferred)
                 bms_fab_models.lib    behavioural SPICE subckts bound
                                       to the symbols via Sim.* fields
                                       (testbench lives IN the
                                       connector models: J1 = pack,
                                       J2 = load)
                 bms_fab_tb.cir        assertion testbench on the
                                       kicad-cli SPICE export itself
                 run_fab_sim.sh        export + ngspice + assertions
                                       (stage 4 of verify_sch.sh)
               PART SUBSTITUTION: the official library has no BQ76952,
               so the fab sheet uses the 6S-capable BQ76930 (same
               feature set as the demo exercises).  Sheet notes list
               the datasheet items to review before fabrication.
logs_ngspice/  ngspice.log, sweep_load.dat, tran_trip.dat, version
logs_xezim/    smoke.log, regress.log (13 scenarios, seed 1),
               xezim_cov.json (functional coverage), version
CROSSCHECK.md  the two simulators put side by side, number by number
```

## Reproduce

```sh
# analog schematic (ngspice, ~1 s)
(cd schematic && ./run_ngspice.sh)

# RNM + firmware + UVM-MS (xezim; smoke ~2 min, regress ~20 min)
./run_xezim_evidence.sh
```

Tool versions are recorded in `logs_*/**version*`.

## What supports which claim

| Whitepaper claim | Evidence |
| --- | --- |
| Fig. 2 circuit is simulable and its numbers are real | `schematic/*.cir` + `logs_ngspice/ngspice.log` (OP1/OP2/sweep) |
| Smoke numbers (3688 mV cells, ~1000 mA, 25.0 C) | `logs_xezim/smoke.log` + ngspice OP1 (exact match, see CROSSCHECK) |
| 13-scenario regression, 0 failures | `logs_xezim/regress.log` (search `TEST-VERDICT`, `scen`) |
| Config integrity over I2C | `regress.log`: no `never arrived` errors; check exists in `design/tb/bq_pkg.sv` |
| Protection loop-back (trip stops real current) | `regress.log` `PROTECTION CLOSED-LOOP` lines + ngspice OP2 and `bms_trip.cir` (4200 -> 0 mA) |
| Balancing closed-loop (right cell, 40 mV droop) | `regress.log` `BALANCING CLOSED-LOOP` line, scenario 9 |
| The 40 mV droop is physics, not a fitted number | `logs_ngspice/full_board.log` OP2: the bleed network derives 39.7 mV (1.98 mA through 2 x 10 Ohm sense lines) |
| Pin-level open-drain I2C (wired-AND) | `full_board.log` transient: SDA at 0 V while either side pulls, 3.3 V released; `full_i2c_bus.dat` |
| The FAB SCHEMATIC itself is simulatable | `logs_ngspice/fab_sim.log`: ngspice on the kicad-cli export, 4 asserted operating points incl. the 100R-filter balancing droop derived from the sheet's own values |
| Functional coverage over corner x response | `logs_xezim/xezim_cov.json` |
| Bring-up bugs (START edge, array args, A-vs-mA) | fix-site comments in `design/rnm/bq76952_rnm.sv`, `design/tb/bq_proxy_pkg.sv`/`bq_bridge.sv`, and the whitepaper's Results section |

Provenance note: the design was authored for this demonstrator; the
architecture is modelled on the open 6S-BMS project (STM32G0B1 +
BQ76952) and TI's BQ76952, with the register-map simplifications the
whitepaper documents.  No external code is included.
