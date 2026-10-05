`timescale 1ns/1ps
//======================================================================
// top_i2cdrv -- the I2C DRIVER RUNG's board top: the same BMS board,
// reached through the GENERIC pin bridge (the bit-banged master now
// lives in the Renode harness, not in the firmware; the firmware uses
// the real STM32 I2C controller).
// Pin map: out[0] = SCL, out[1] = SDA_PULL; in[0] = resolved SDA.
// Same scenario timeline as every BMS mission.
//======================================================================
module top_i2cdrv;

  import bq_types_pkg::*;

  logic [1:0] mcu_out;
  wire  scl        = mcu_out[0];
  wire  m_sda_pull = mcu_out[1];
  logic s_sda_pull;
  wire  sda_bus = (m_sda_pull || s_sda_pull) ? 1'b0 : 1'b1;

  logic dsg_en, chg_en;

  real c_v = 3.7, rint_v = 0.012, iload_v = 1.0, temp_v = 25.0;
  real zero = 0.0;
  wreal p_c, p_rint, p_iload, p_temp, p_z;
  assign p_c     = c_v;
  assign p_rint  = rint_v;
  assign p_iload = iload_v;
  assign p_temp  = temp_v;
  assign p_z     = zero;
  logic intf_en = 1'b0;

  initial begin
    #15_000_000;
    iload_v = 4.2;
    $display("[scenario] t=%0t: load raised to 4.2 A (overload)", $time);
    #25_000_000;
    iload_v = 0.5;
    $display("[scenario] t=%0t: load reduced to 0.5 A", $time);
  end

  bq_board u_board (
    .scl         (scl),
    .sda_bus     (sda_bus),
    .sda_pull    (s_sda_pull),
    .p_c1 (p_c), .p_c2 (p_c), .p_c3 (p_c),
    .p_c4 (p_c), .p_c5 (p_c), .p_c6 (p_c),
    .p_rint      (p_rint),
    .p_iload     (p_iload),
    .p_temp      (p_temp),
    .p_vgain_tol (p_z),
    .p_ctol      (p_z),
    .p_coff_ma   (p_z),
    .intf_en     (intf_en),
    .dsg_en      (dsg_en),
    .chg_en      (chg_en),
    .i_act_tap   ()
  );

  wire alert = 1'b0;
  pin_bridge #(.PORT(43605), .N_OUT(2), .N_IN(1), .OUT_RESET(1))
  u_bridge (
    .in_pins  (sda_bus),
    .alert    (alert),
    .out_pins (mcu_out)
  );

  always @(negedge dsg_en)
    $display("[board] t=%0t: AFE opened DSG (protection trip)", $time);
  always @(posedge dsg_en)
    if ($time > 0)
      $display("[board] t=%0t: AFE closed DSG (recovered)", $time);

endmodule : top_i2cdrv
