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
renode/        SoC-emulator <-> xezim CO-SIMULATION, two backends:
               real bare-metal ARM firmware on an emulated MCU drives
               the SV-RNM board over a lockstep TCP bridge.
               Backend 1 (run_cosim.sh): Renode, STM32G0 (Cortex-M0+,
               the schematic's U2 family), bridge = custom MMIO
               peripheral (Bridge.cs).
               Backend 2 (run_cosim_qemu.sh): MAINLINE QEMU 9.2.4
               (xPack, zero modifications), STM32F405/netduinoplus2
               (Cortex-M4), bridge = the same line protocol over
               USART1 whose chardev is a TCP socket -- the
               bolt-onto-a-spare-UART pattern pre-silicon teams use.
               Same mission logic (fw_arm/main.c), per-platform HALs
               (hal_renode.c / hal_qemu.c); the board timeline is
               byte-for-byte identical under both (and under the
               F4-vs-G0 CPU swap), because board time is a function
               of the firmware's stated delays alone.
                 fw_arm/        the firmware (natural blocking C,
                                bit-banged I2C, UART reporting) +
                                startup/linker/Makefile
                 bridge/        xezim_bridge.c (DPI socket server) +
                                renode_bridge.sv (replaces the tick
                                shim; board time advances ONLY on the
                                firmware's own delays)
                 Bridge.cs      Renode MMIO peripheral (PINS/ADV/SDA/
                                FIN registers -> RPC to xezim)
                 cosim.resc     machine script; run_cosim.sh runs it
                 check_cosim.py cross-domain checker and pass gate:
                                cross-examines the firmware's UART log
                                against the board's event log (rules
                                R1 protection / R2 telemetry /
                                R3 false-trip / R4 bus+mission)
                 run_faults.sh  fault-injection campaign: one injected
                                defect per layer (firmware config,
                                firmware protocol, analog front-end,
                                bridge/pin path), each caught by a
                                different rule, clean run still green
               Tools (no sudo): ~/renode-portable (v1.17.0),
               ~/arm-gcc (xPack 15.2.1); get_tools.sh fetches both.
               V2 BRIDGE (run_cosim_v2.sh): VIRTUAL-TIME QUANTUM
               COUPLING on the Renode backend.  No ADV register: the
               emulated CPU's own virtual clock drives board time
               (Bridge2.cs fires one sync per 10 us quantum, plus a
               flush before every pin access, so compute costs board
               time and I2C edges stay cycle-honest), and the AFE's
               ALERT is a real NVIC interrupt (level-held, ISR masks
               itself).  Result: the ISR runs at t=15.250 ms, the
               exact quantum of the board's assert (v1's poll-based
               discovery was 18.6 ms); the remaining 1.66 ms to the
               firmware's reaction is its own main-loop service
               latency, now a measured property of the firmware
               because execution cost is real.  fw_arm/main_v2.c +
               startup_v2.c (full vector table), top_v2.sv,
               bridge/*2.* -- v1 untouched.
logs_renode/   uart.log (the firmware's own account of the trip-and-
               recover mission), xezim.log, renode.log
               TLM-2.0 SHIM (run_cosim_tlm.sh, tlm_shim/shim.cpp):
               the RNM board presented as a STANDARD IEEE 1666
               TLM-2.0 TARGET (Accellera SystemC 2.3.4, built
               sudo-free by get_systemc.sh into ~/systemc).  Three
               host processes: unmodified QEMU (same fw_qemu.elf)
               -> SystemC shim, where every firmware action crosses
               a genuine tlm_generic_payload b_transport into
               rnm_board_tlm (register map PINS/SDA/ADV/FIN, sc_time
               advancing with every ADV) -> the untouched xezim
               board server.  Any TLM initiator (QBox, a remote-port
               endpoint, a vendor virtual platform) can bind to the
               same target.  14,439 TLM transactions per mission,
               sc_time tracks board time, board ends at
               t=52233121000 exactly: fourth transport, same
               nanosecond.  Evidence: logs_tlm/.
               BENCH-LIKE TIME ON MAINLINE QEMU (run_cosim_qv2.sh,
               fw_arm/main_qv2.c): QEMU -icount shift=3 prices every
               instruction; the firmware meters its own measured
               execution (free-running SysTick = virtual-time ruler)
               to the board as "A" time beacons every ~10 us, with a
               flush before every pin edge; ALERT rides every ack and
               is dispatched within a tick.  Harness time is excluded
               from the ledger (ack waits, console readiness), which
               is what makes runs reproducible: uart log and board
               events byte-identical, harness finish +/-1 us over a
               43 ms mission (logs_qv2/validate.log).  Mission log
               captures a genuine torn read (ss=0x0 beside i=4200mA,
               trip between the poll's two reads) and the measured
               266-471 us event-to-dispatch latency across the drift
               sweep.  Faults + drift re-validated on this backend
               (logs_qv2/faults, logs_qv2/drift).  This is the
               backend the whitepaper presents.
logs_v2/       the quantum-coupled run: uart.log shows "ALERT IRQ:
               isr at t=15250us" -- interrupt delivery at the assert
               quantum -- plus the same telemetry the checker grades
               drift/     clock-drift sweep (run_drift.sh): the AFE's
                          measurement period swept +/-2% against the
                          MCU's clock (-D AFE_DRIFT_PPM=<n>, a new
                          defaulted TMEAS_NS parameter on bq_board);
                          the trip's phase slides deterministically,
                          sweep.log tabulates trip vs ISR instant,
                          checker green at every point -- the bench
                          samples this space once per power cycle,
                          the co-sim walks it
               faults/    the five-fault campaign re-run under the
                          v2 coupling (BACKEND=v2 run_faults.sh),
                          same verdicts R1-R4, clean green
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
| The FAB SCHEMATIC itself is simulatable | `logs_ngspice/fab_sim.log`: ngspice on the kicad-cli export -- 4 asserted operating points (incl. the 100R-filter balancing droop derived from the sheet's own values), a 4.2 A trip TRANSIENT (waveform in `fab_trip.dat`), and an AC sweep of the kelvin filter (fc = 7957.7 Hz measured vs 7957.7 analytic; response in `fab_kelvin_ac.dat`) |
| Functional coverage over corner x response | `logs_xezim/xezim_cov.json` |
| Bring-up bugs (START edge, array args, A-vs-mA) | fix-site comments in `design/rnm/bq76952_rnm.sv`, `design/tb/bq_proxy_pkg.sv`/`bq_bridge.sv`, and the whitepaper's Results section |
| Injected defects in ANY layer are caught, each by a different rule | `logs_renode/faults/`: five-run campaign — clean passes; a byte-swapped OCD threshold (firmware config) trips R1 protection-missing; an off-by-one cell-register read (firmware protocol) trips R2 telemetry-vs-board-truth; a +2.5 A analog current-path offset (RNM) trips R3 false-trip; a stuck SDA readback (bridge/pin mux) trips R4 bus health — per-run logs + `summary.log` |
| Under quantum coupling, firmware compute costs board time and interrupts land at the event | `logs_v2/uart.log`: ALERT ISR at t=15250us (the assert quantum, vs 18.6 ms polled in v1); the firmware's 1.66 ms main-loop service latency becomes a measured property; same checker passes |
| The board is a standard IEEE 1666 TLM-2.0 target | `logs_tlm/`: the same mission crosses a genuine SystemC TLM-2.0 socket (14,439 generic-payload transactions, sc_time locked to board time), board ends at t=52233121000 exactly, same checker PASS -- any TLM initiator can drive the same board |
| The co-sim is emulator-agnostic: mainline QEMU reproduces the board timeline byte-for-byte | `logs_qemu/`: the same mission firmware on unmodified QEMU 9.2.4 (STM32F405, bridge over a USART TCP chardev) finishes at t=52233121000 exactly, same samples, same checker PASS, ~8 s wall |
| REAL firmware on an emulated SoC drives the RNM board | `logs_renode/uart.log`: ARM firmware (Renode STM32G0, the schematic's U2 family) configures the AFE over bit-banged I2C, reads 3688 mV / ~1000 mA, sees the OCD trip (3701 mV, 1 mA), recovers the latch, confirms 3694 mV / 499 mA -- every number consistent with the xezim, ngspice and UVM domains |

Provenance note: the design was authored for this demonstrator; the
architecture is modelled on the open 6S-BMS project (STM32G0B1 +
BQ76952) and TI's BQ76952, with the register-map simplifications the
whitepaper documents.  No external code is included.
