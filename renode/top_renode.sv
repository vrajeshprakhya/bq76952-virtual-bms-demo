`timescale 1ns/1ps
//======================================================================
// top_renode -- the virtual 6S BMS board (the repo's own SV-RNM, from
// design/rnm) with the MCU replaced by a Renode-emulated STM32 running
// REAL bare-metal firmware, coupled through renode_bridge.
//
//   Renode (STM32F4, fw_arm/fw.elf)
//        | MMIO peripheral <-> TCP socket, lockstep
//        v
//   renode_bridge  --SCL / SDA_pull-->  open-drain bus  <-->  AFE
//                                                             (RNM)
//   scenario timeline below drives the PACK: 1 A normal, 4.2 A
//   overload at 15 ms (AFE trips OCD), load removed at 40 ms
//   (firmware recovers the latch over I2C).
//======================================================================
module top_renode;

  import bq_types_pkg::*;

  //--- I2C bus ---------------------------------------------------------
  logic scl, m_sda_pull, s_sda_pull, sda_bus;
  assign sda_bus = (m_sda_pull || s_sda_pull) ? 1'b0 : 1'b1;

  logic dsg_en, chg_en;

  //--- scenario: pack state over BOARD time ----------------------------
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
    #15_000_000;                        // t = 15 ms: overload
    iload_v = 4.2;
    $display("[scenario] t=%0t: load raised to 4.2 A (overload)", $time);
    #25_000_000;                        // t = 40 ms: load removed
    iload_v = 0.5;
    $display("[scenario] t=%0t: load reduced to 0.5 A", $time);
  end

  //--- the board (same RNM the UVM regression runs against) ------------
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

  //--- the SoC, by proxy ------------------------------------------------
  renode_bridge #(.PORT(43601)) u_bridge (
    .sda_bus  (sda_bus),
    .scl      (scl),
    .sda_pull (m_sda_pull)
  );

  //--- board-side event trace ------------------------------------------
  always @(negedge dsg_en)
    $display("[board] t=%0t: AFE opened DSG (protection trip)", $time);
  always @(posedge dsg_en)
    if ($time > 0)
      $display("[board] t=%0t: AFE closed DSG (recovered)", $time);

endmodule : top_renode
