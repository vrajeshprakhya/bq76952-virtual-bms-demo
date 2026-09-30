# Virtual 6S BMS — BQ76952-class AFE + pin-level I²C + real host firmware + UVM-MS

Fourth virtual-board demo (after `~/tcd1304_vboard`, `~/loadcell_vboard`,
`~/bms_vboard`), modelled on the production-BMS architecture of the
public 6S-BMS project (STM32G0B1 + BQ76952): the analog measurement and
protection intelligence lives in a **separate mixed-signal AFE with a
register map**, and the host firmware's only connection to the analog
world is a **pin-level I²C bus**.  Runs on **xezim**.

What is new versus the first three demos:
* the firmware↔board boundary is a real serial bus: bit-banged
  open-drain I²C master in C, START/STOP-detecting register-map slave
  in the RNM model — every threshold, measurement and balancing
  command crosses it as bus traffic
* the AFE has its OWN protection engine; the host *configures* it
  (CUV/COV/OCD thresholds written over I²C) and the scoreboard checks
  the thresholds physically present in the AFE's registers — proof the
  configuration crossed the bus
* six cells: imbalance scenarios, and host-commanded **cell balancing**
  with the BQ-family measurement artifact (a cell being bled through
  its sense line reads ~40 mV low)

```
  UVM-MS env: sequences -> driver -> proxy      scoreboard <- analysis
       |  (push 6 cell OCVs / load / temp / board build)
       v
  bq_bridge --wreal--> bq_board (RNM)
             <--pull-- host mirrors (DPI) AND AFE registers (OOMR)
                            |
   6S pack + shunt --> BQ76952-class AFE:  measurement engine,
       ^    (UDN)      protection engine, FET drive, CB, I2C slave
       |                     ^      |
       +--- DSG loop-back ---+      | pin-level I2C (open-drain SDA)
                                    v
                          mcu_virtual -- REAL HOST FIRMWARE (DPI tick)
```

## Run

```sh
./run.sh                        # regress: corners + protections +
                                #          balancing + hero (~270 ms sim)
TEST=bq_smoke_test ./run.sh     # one nominal operating point
SEED=7 ./run.sh +n_corners=8    # more random corners
WAVES=1 ./run.sh                # FST dump of the board scope
```

Note: xezim stdout is block-buffered through the tee pipe — a quiet
`build/run.log` does not mean a hung run (`pgrep xezim` shows CPU).

## What each piece is

| Piece | File | Behaviours captured |
|---|---|---|
| 6S pack + load | `rnm/pack_rnm.sv` | per-cell OCV, IR sag, shunt sense; the **loop-back**: current flows only while the AFE's DSG FET is closed |
| EMI source | `rnm/ripple_interferer.sv` | 20 kHz DC/DC ripple as a second driver on the shunt-sense UDN (sum resolution) |
| AFE | `rnm/bq76952_rnm.sv` | 250 µs measurement loop (cell gain tol + noise, current, temp), balancing read-droop artifact, protection engine with host-written thresholds (CUV/COV hysteresis + recovery, OCD **latched** until a recover write, OT), FET outputs = protection AND host allow, pin-level I²C slave with register pointer + burst auto-increment, RO ranges write-protected |
| Host firmware | `fw/firmware.c` | real C: queue-based bit-banged I²C master (~415 kHz), config write-out (thresholds, enables, FET allow), 2 ms poll loop (cells burst read, current, temp, safety, FET status), balancing policy with hysteresis, recover-write on host fault reset |
| Virtual MCU | `mcu/mcu_virtual.sv` | 20 MHz DPI tick, SDA-before-SCL ordering for clean START/STOP — the Renode/STM32G0B1 swap-in point |
| MS bridge + proxy | `tb/bq_bridge.sv`, `tb/bq_proxy_pkg.sv` | UVM-MS 4.2.1/4.2.3; pulls BOTH sides of the bus: host mirrors via DPI and AFE registers via OOMR |
| UVM-MS env | `tb/bq_pkg.sv`, `tb/test_lib.svh` | constrained-random pack states, two-pass prediction, config-integrity check, balancing-target check, trip latency, coverage crosses |

## Demo register map (deviations from the real BQ76952)

The real part reaches RAM configuration through the 0x3E/0x3F
subcommand + 0x60 checksum protocol; this demo flattens those into
directly writable registers 0x90–0x99 and returns temperature in
0.1 °C instead of 0.1 K.  Direct-command measurement addresses (0x14+,
0x3A, 0x7F) follow the real map.

## What the regress demonstrates

* **Corners**: 6 cell OCVs x load x temp x cell-ADC gain tol x current
  gain/offset — host-read values match the two-pass prediction.
* **Config integrity**: the CUV/OCD thresholds inside the AFE equal the
  values the host firmware wrote over I²C, every scenario.
* **Protections**: CUV/COV/OCD/OT each trip the right FET in the AFE
  (not the host), the host reads the safety byte over I²C, and the
  analog loop-back stops the real current.
* **Balancing closed-loop**: an imbalanced cell (+90 mV) makes the host
  write the CB mask for exactly that cell; the AFE register shows it,
  and the cell's reading droops the predicted 40 mV.
* **Hero**: normal -> overload (AFE latches OCD, current physically
  stops) -> load removed + host recover write over I²C -> running.

## Bring-up bugs the bench itself caught

1. The I²C slave counted the SCL falling edge that completes a START
   as a data-bit boundary, assembled the address one bit short and
   NACKed everything — every host read returned 0xFF.
2. Cell voltages pushed through an unpacked-array argument on the
   virtual proxy method arrived empty (simulator edge); the AFE then
   measured 0 V and its own CUV latched DSG off.  Scalars everywhere
   on the push path now (see comments).
3. A units error in the AFE current path (A vs mA) — reported current
   was 1000x low; caught by the smoke test's current check.

## Deliberately out of scope

Charge-side current, coulomb counting, the subcommand/checksum config
protocol, I²C clock stretching and multi-master, CAN, and a full ISS
(the tick shim is the Renode swap-in point).  Host policy constants
are mirrored in `bq_pkg.sv` — change both.
