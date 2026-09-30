`timescale 1ns/1ps
//======================================================================
// top -- virtual 6S BMS board (BQ76952-class AFE), UVM-MS testbench.
//
//   UVM-MS env: sequences -> driver -> proxy      scoreboard <- analysis
//        |  (push pack state / board build)
//        v
//   bq_bridge --wreal--> bq_board (RNM)
//             <--pull--     |    ^
//                    BQ76952 AFE |  FET loop-back into the pack model
//                        ^
//                        | pin-level I2C (open-drain SDA)
//                        v
//                   mcu_virtual -- REAL HOST FIRMWARE (DPI tick)
//
// The open-drain SDA bus is resolved here: either side pulling wins.
//======================================================================
module top;

  import uvm_pkg::*;
  import uvm_ms_pkg::*;
  import bq_types_pkg::*;
  import bq_proxy_pkg::*;
  import bq_pkg::*;
  `include "uvm_macros.svh"

  `include "test_lib.svh"

  //--- I2C bus ---------------------------------------------------------
  logic scl, m_sda_pull, s_sda_pull, sda_bus;
  assign sda_bus = (m_sda_pull || s_sda_pull) ? 1'b0 : 1'b1;

  //--- pins ------------------------------------------------------------
  logic dsg_en, chg_en, frame_done;

  //--- scenario control nets (bridge -> board) -------------------------
  wreal p_c1, p_c2, p_c3, p_c4, p_c5, p_c6;
  wreal p_rint, p_iload, p_temp, p_vgain_tol, p_ctol, p_coff_ma;
  logic intf_en;

  //--- analog tap ------------------------------------------------------
  wreal i_act;

  //--- the virtual board (pack + AFE) ----------------------------------
  bq_board u_board (
    .scl         (scl),
    .sda_bus     (sda_bus),
    .sda_pull    (s_sda_pull),
    .p_c1 (p_c1), .p_c2 (p_c2), .p_c3 (p_c3),
    .p_c4 (p_c4), .p_c5 (p_c5), .p_c6 (p_c6),
    .p_rint      (p_rint),
    .p_iload     (p_iload),
    .p_temp      (p_temp),
    .p_vgain_tol (p_vgain_tol),
    .p_ctol      (p_ctol),
    .p_coff_ma   (p_coff_ma),
    .intf_en     (intf_en),
    .dsg_en      (dsg_en),
    .chg_en      (chg_en),
    .i_act_tap   (i_act)
  );

  //--- the virtual host MCU running the real firmware ------------------
  mcu_virtual #(.TICK_NS(50)) u_mcu (
    .sda_bus    (sda_bus),
    .scl        (scl),
    .sda_pull   (m_sda_pull),
    .frame_done (frame_done)
  );

  //--- the MS bridge ----------------------------------------------------
  bq_bridge u_bridge (
    .p_c1 (p_c1), .p_c2 (p_c2), .p_c3 (p_c3),
    .p_c4 (p_c4), .p_c5 (p_c5), .p_c6 (p_c6),
    .p_rint      (p_rint),
    .p_iload     (p_iload),
    .p_temp      (p_temp),
    .p_vgain_tol (p_vgain_tol),
    .p_ctol      (p_ctol),
    .p_coff_ma   (p_coff_ma),
    .intf_en     (intf_en),
    .frame_done  (frame_done),
    .dsg_en      (dsg_en),
    .chg_en      (chg_en),
    .i_act       (i_act)
  );

  initial begin
    `uvm_info("TOP", "virtual 6S BMS: pack RNM + BQ76952-class AFE + pin-level I2C + real host firmware via DPI + UVM-MS", UVM_LOW)
    run_test();
  end

endmodule : top
