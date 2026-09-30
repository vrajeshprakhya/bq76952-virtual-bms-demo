`timescale 1ns/1ps
//======================================================================
// bq_board -- the virtual 6S BMS board.
//
//   cells 1..6 (scenario) --> pack_rnm --terminals--> BQ76952 AFE
//        |                       ^  | shunt UDN <-- DC/DC ripple
//        |                       |  +--> i_act tap
//        |          DSG/CHG <---+------ AFE FET drive (LOOP-BACK)
//        |
//   host MCU <====== pin-level I2C (SCL, open-drain SDA) ======> AFE
//======================================================================
module bq_board import bq_types_pkg::*; (
  // host-facing I2C
  input  logic scl,
  input  logic sda_bus,
  output logic sda_pull,
  // scenario controls from the MS bridge
  input  wreal p_c1, p_c2, p_c3, p_c4, p_c5, p_c6,
  input  wreal p_rint,
  input  wreal p_iload,
  input  wreal p_temp,
  input  wreal p_vgain_tol,
  input  wreal p_ctol,
  input  wreal p_coff_ma,
  input  logic intf_en,
  // observability
  output logic dsg_en,
  output logic chg_en,
  output wreal i_act_tap
);

  wreal       w_vc1, w_vc2, w_vc3, w_vc4, w_vc5, w_vc6;
  isense_node n_shunt;
  wreal       w_iact;

  pack_rnm u_pack (
    .p_c1 (p_c1), .p_c2 (p_c2), .p_c3 (p_c3),
    .p_c4 (p_c4), .p_c5 (p_c5), .p_c6 (p_c6),
    .rint   (p_rint),
    .i_load (p_iload),
    .dsg_en (dsg_en),
    .vc1 (w_vc1), .vc2 (w_vc2), .vc3 (w_vc3),
    .vc4 (w_vc4), .vc5 (w_vc5), .vc6 (w_vc6),
    .v_shunt (n_shunt),
    .i_act   (w_iact)
  );

  // second driver on the same UDN net
  ripple_interferer u_intf (
    .en (intf_en),
    .y  (n_shunt)
  );

  bq76952_rnm u_afe (
    .vc1 (w_vc1), .vc2 (w_vc2), .vc3 (w_vc3),
    .vc4 (w_vc4), .vc5 (w_vc5), .vc6 (w_vc6),
    .v_shunt   (n_shunt),
    .temp_c    (p_temp),
    .vgain_tol (p_vgain_tol),
    .ctol      (p_ctol),
    .coff_ma   (p_coff_ma),
    .scl       (scl),
    .sda_bus   (sda_bus),
    .sda_pull  (sda_pull),
    .dsg_en    (dsg_en),
    .chg_en    (chg_en)
  );

  assign i_act_tap = w_iact;

endmodule : bq_board
