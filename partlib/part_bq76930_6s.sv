`timescale 1ns/1ps
//======================================================================
// part_bq76930_6s -- the battery-monitor AFE as it sits on the
// schematic: its ports are the BQ76930 model's own pin names, so the
// bench generator wires it by net name with no hand mapping.
//
// Inside, it adapts the pins to the behavioural core (bq76952_rnm,
// the register map, measurement engine, protection engine and I2C
// slave). The adaptation is the part's datasheet, not the board's:
//
//   * cell n is read DIFFERENTIALLY across two filtered pins. In a
//     6-cell build the unused group inputs are shorted, so the six
//     cells sit across VC0-VC1-VC2-VC3 (group A) and VC5B-VC6-VC7-VC8
//     (group B).
//   * pack current is the Kelvin pair SRP - SRN over the shunt.
//   * DSG/CHG are gate-drive VOLTAGES (10 V on, 0 V off), so the gate
//     resistor networks and the FET thresholds on the board decide
//     what the FETs do.
//   * REGOUT is the 3.3 V rail.
//   * ALERT is a pin: high while any safety-status bit is latched.
//
// Fault and drift knobs match the hand-built bench (-D FAULT_COFF,
// -D AFE_DRIFT_PPM=<n>), so the same campaigns run on either.
//======================================================================
module part_bq76930_6s import bq_types_pkg::*; #(
  parameter real TMEAS_NS = 250000.0,
  parameter real TEMP_C   = 25.0
) (
  input  real  vc0, vc1, vc2, vc3, vc5b, vc6, vc7, vc8,
  input  real  srp, srn,
  output real  dsg, chg, regout,
  input  logic scl,
  input  logic sda_bus,
  output logic sda_pull,
  output logic alert
);

`ifdef AFE_DRIFT_PPM
  localparam real TM = TMEAS_NS * (1.0 + (`AFE_DRIFT_PPM) / 1.0e6);
`else
  localparam real TM = TMEAS_NS;
`endif
`ifdef FAULT_COFF
  real coff_v = 2500.0;    // INJECTED ANALOG FAULT: +2500 mA offset
`else
  real coff_v = 0.0;
`endif

  wreal c1, c2, c3, c4, c5, c6, w_temp, w_zero, w_coff;
  isense_node v_shunt;
  real temp_v = TEMP_C, zero_v = 0.0;

  assign c1 = vc1 - vc0;
  assign c2 = vc2 - vc1;
  assign c3 = vc3 - vc2;
  assign c4 = vc6 - vc5b;
  assign c5 = vc7 - vc6;
  assign c6 = vc8 - vc7;
  assign v_shunt = srp - srn;
  assign w_temp = temp_v;
  assign w_zero = zero_v;
  assign w_coff = coff_v;

  logic dsg_en, chg_en;

  bq76952_rnm #(.TMEAS_NS(TM)) u_core (
    .vc1 (c1), .vc2 (c2), .vc3 (c3), .vc4 (c4), .vc5 (c5), .vc6 (c6),
    .v_shunt   (v_shunt),
    .temp_c    (w_temp),
    .vgain_tol (w_zero),
    .ctol      (w_zero),
    .coff_ma   (w_coff),
    .scl       (scl),
    .sda_bus   (sda_bus),
    .sda_pull  (sda_pull),
    .dsg_en    (dsg_en),
    .chg_en    (chg_en)
  );

  assign dsg    = (dsg_en === 1'b1) ? 10.0 : 0.0;
  assign chg    = (chg_en === 1'b1) ? 10.0 : 0.0;
  assign regout = 3.3;

  initial begin
    alert = 1'b0;
    $display("[board] AFE measurement period = %.1f ns", TM);
  end
  always begin
    #1000;
    alert = (u_core.regs[8'h03] != 8'h00);
  end
  always @(posedge alert)
    $display("[board] t=%0t: ALERT asserted (safety status nonzero)", $time);
  always @(negedge dsg_en)
    $display("[board] t=%0t: AFE opened DSG (protection trip)", $time);
  always @(posedge dsg_en)
    if ($time > 0)
      $display("[board] t=%0t: AFE closed DSG (recovered)", $time);

endmodule : part_bq76930_6s
