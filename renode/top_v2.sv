`timescale 1ns/1ps
//======================================================================
// top_v2 -- the virtual 6S BMS board under the v2 VIRTUAL-TIME
// QUANTUM-COUPLED bridge.
//
// Differences from top_renode (v1 lockstep):
//   * Board time is driven by Renode's quantum engine (the emulated
//     CPU's own virtual clock), not by firmware-declared delays, so
//     the firmware's real execution cost is what spends board time.
//   * The AFE's safety status is surfaced as an ALERT level, carried
//     back in every bridge ack; Renode raises a real NVIC interrupt
//     from it, so the firmware learns of the trip asynchronously
//     (microseconds) instead of at its next poll (milliseconds).
// Same board, same scenario timeline.
//======================================================================
module top_v2;

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
    #15_000_000;
    iload_v = 4.2;
    $display("[scenario] t=%0t: load raised to 4.2 A (overload)", $time);
    #25_000_000;
    iload_v = 0.5;
    $display("[scenario] t=%0t: load reduced to 0.5 A", $time);
  end

  //--- the board --------------------------------------------------------
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

  //--- ALERT: any latched safety bit asserts the pin -------------------
  // (sampled periodically; 1 us resolution is far below the quantum)
  logic alert = 1'b0;
  always begin
    #1000;
    alert = (u_board.u_afe.regs[8'h03] != 8'h00);
  end
  always @(posedge alert)
    $display("[board] t=%0t: ALERT asserted (safety status nonzero)",
             $time);

  //--- the SoC, by quantum-coupled proxy --------------------------------
  renode_bridge2 #(.PORT(43602)) u_bridge (
    .sda_bus  (sda_bus),
    .alert    (alert),
    .scl      (scl),
    .sda_pull (m_sda_pull)
  );

  //--- board-side event trace ------------------------------------------
  always @(negedge dsg_en)
    $display("[board] t=%0t: AFE opened DSG (protection trip)", $time);
  always @(posedge dsg_en)
    if ($time > 0)
      $display("[board] t=%0t: AFE closed DSG (recovered)", $time);

endmodule : top_v2
