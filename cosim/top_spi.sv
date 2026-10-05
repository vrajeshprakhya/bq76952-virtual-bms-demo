`timescale 1ns/1ps
//======================================================================
// top_spi -- TRANSPORTABILITY PROOF: a second protocol on the same
// framework.  The load-cell chain (bridge sensor -> RC filter ->
// HX717 24-bit ADC, an SPI-family two-wire protocol: SCLK out, DOUT
// in) replaces the BMS board; the GENERIC pin_bridge replaces the
// I2C-named one; the same bench-like firmware flow drives it from
// unmodified mainline QEMU.
//
// Pin map (the bridge itself is protocol-blind):
//   out_pins[0] = SCLK      in_pins[0] = DOUT      alert: unused (0)
//
// Scenario: the scale is empty (0 g) until t = 151 ms, when a 2000 g
// weight lands.  Expected ADC delta, from the chain's physics:
// 2 mV/V sensitivity x 5 V excitation x (2000/5000) = 4 mV in;
// full scale 0.5*5V/128 = 19.531 mV; delta = 4/19.531 * 2^23
// = 1,717,987 counts.
//======================================================================
module top_spi;

  import lc_types_pkg::*;

  logic sclk, dout;

  //--- scenario -------------------------------------------------------
  real force_v = 0.0, vexc_v = 5.0, zero_v = 0.0;
  wreal p_force, p_vexc, p_z;
  assign p_force = force_v;
  assign p_vexc  = vexc_v;
  assign p_z     = zero_v;
  logic [1:0] fault_mode = 2'b00;
  logic       intf_en    = 1'b0;

  initial begin
    #151_000_000;
    force_v = 2000.0;
    $display("[scenario] t=%0t: force step to 2000 g", $time);
  end

  //--- the board (same RNM the loadcell UVM regression uses) ----------
  lc_board u_board (
    .sclk         (sclk),
    .dout         (dout),
    .p_force      (p_force),
    .p_vexc       (p_vexc),
    .p_sens_tol   (p_z),
    .p_zero_off   (p_z),
    .fault_mode   (fault_mode),
    .intf_en      (intf_en),
    .v_bridge_tap (),
    .v_adc_in_tap ()
  );

  //--- the generic bridge ----------------------------------------------
  wire alert = 1'b0;
  pin_bridge #(.PORT(43604), .N_OUT(1), .N_IN(1), .OUT_RESET(0))
  u_bridge (
    .in_pins  (dout),
    .alert    (alert),
    .out_pins (sclk)
  );

endmodule : top_spi
