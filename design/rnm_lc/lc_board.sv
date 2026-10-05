`timescale 1ns/1ps
//======================================================================
// lc_board -- the virtual load-cell board: one measurement channel,
// functional-block RNM.
//
//   force ->[ load cell / bridge ]--UDN-->[ RC filter ]-->[ HX717 ]
//                    ^  (sum)                                |
//              mains interferer                        DOUT / SCLK
//                                                            |
//                                                       STM32 firmware
//
// Scenario knobs arrive as wreal control nets from the MS bridge
// (p_force, p_vexc, p_sens_tol, p_zero_off) plus fault_mode / intf_en.
//======================================================================
module lc_board import lc_types_pkg::*; (
  // firmware-facing interface
  input  logic       sclk,
  output logic       dout,
  // scenario controls from the MS bridge
  input  wreal       p_force,
  input  wreal       p_vexc,
  input  wreal       p_sens_tol,
  input  wreal       p_zero_off,
  input  logic [1:0] fault_mode,
  input  logic       intf_en,
  // analog taps for the bridge pull API
  output wreal       v_bridge_tap,
  output wreal       v_adc_in_tap
);

  bridge_node n_bridge;      // summed bridge output
  wreal       w_filt;

  loadcell_rnm u_cell (
    .force_g    (p_force),
    .vexc       (p_vexc),
    .sens_tol   (p_sens_tol),
    .zero_off   (p_zero_off),
    .fault_mode (fault_mode),
    .vdiff      (n_bridge)
  );

  // second driver on the same UDN net
  mains_interferer u_intf (
    .en (intf_en),
    .y  (n_bridge)
  );

  rc_filter_rnm u_filt (
    .vin  (n_bridge),
    .vout (w_filt)
  );

  hx717_rnm u_adc (
    .avdd (p_vexc),           // ratiometric: AVDD = excitation
    .vin  (w_filt),
    .sclk (sclk),
    .dout (dout)
  );

  assign v_bridge_tap = n_bridge;
  assign v_adc_in_tap = w_filt;

endmodule : lc_board
