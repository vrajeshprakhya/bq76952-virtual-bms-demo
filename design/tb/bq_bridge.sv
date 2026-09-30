`timescale 1ns/1ps
//======================================================================
// bq_bridge -- the MS Bridge (UVM-MS clause 4.2.3) for the virtual
// 6S BMS board.  Pushes the pack/board scenario onto wreal control
// nets; pulls BOTH sides of the I2C boundary: the host's belief (DPI
// mirrors) and the AFE's actual registers + FET pins + analog current
// (OOMR / taps).  That double view is what lets the scoreboard prove
// the register map carried the truth across the bus.
//======================================================================
module bq_bridge (
  // push side: scenario -> board
  output wreal p_c1, p_c2, p_c3, p_c4, p_c5, p_c6,
  output wreal p_rint,
  output wreal p_iload,
  output wreal p_temp,
  output wreal p_vgain_tol,
  output wreal p_ctol,
  output wreal p_coff_ma,
  output logic intf_en,
  // pull side
  input  logic frame_done,
  input  logic dsg_en,
  input  logic chg_en,
  input  wreal i_act
);

  import uvm_pkg::*;
  import uvm_ms_pkg::*;
  import bq_proxy_pkg::*;
  `include "uvm_macros.svh"
  `include "fw_dpi.svh"

  //--- pushed attributes ---------------------------------------------
  // scalars, not an array: continuous assigns fed from unpacked-array
  // elements missed both the initializer and later element writes here
  // (every cell then read 0 V) -- found by the smoke test
  real c0_v = 3.7, c1_v = 3.7, c2_v = 3.7, c3_v = 3.7, c4_v = 3.7, c5_v = 3.7;
  real rint_v = 0.012, iload_v = 0.0, temp_v = 25.0;
  real vgt_v = 0.0, ctol_v = 0.0, coff_v = 0.0;

  assign p_c1 = c0_v; assign p_c2 = c1_v; assign p_c3 = c2_v;
  assign p_c4 = c3_v; assign p_c5 = c4_v; assign p_c6 = c5_v;
  assign p_rint      = rint_v;
  assign p_iload     = iload_v;
  assign p_temp      = temp_v;
  assign p_vgain_tol = vgt_v;
  assign p_ctol      = ctol_v;
  assign p_coff_ma   = coff_v;

  logic intf_v = 1'b0;
  assign intf_en = intf_v;

  //--- concrete proxy (UVM-MS 4.2.3: lives in the bridge) ------------
  class bq_proxy_impl extends bq_proxy;

    function new(string name = "bq_proxy_impl");
      super.new(name);
    endfunction

    virtual function void push_scenario(input real c1, input real c2,
                                        input real c3, input real c4,
                                        input real c5, input real c6,
                                        input real rint, input real iload,
                                        input real temp_c,
                                        input real vgain_tol,
                                        input real ctol,
                                        input real coff_ma,
                                        input bit intf_on);
      c0_v = c1; c1_v = c2; c2_v = c3;
      c3_v = c4; c4_v = c5; c5_v = c6;
      rint_v = rint;  iload_v = iload; temp_v = temp_c;
      vgt_v  = vgain_tol; ctol_v = ctol; coff_v = coff_ma;
      intf_v = intf_on;
    endfunction

    virtual function void fw_config(input int reset_faults);
      fw_configure(reset_faults, 1);
    endfunction

    virtual task wait_frame_done();
      @(posedge frame_done);
    endtask

    virtual function int  get_cell_mv(input int idx); return fw_get_cell_mv(idx); endfunction
    virtual function int  get_ma();         return fw_get_ma();         endfunction
    virtual function int  get_t_c10();      return fw_get_t_c10();      endfunction
    virtual function int  get_safety();     return fw_get_safety();     endfunction
    virtual function int  get_fets();       return fw_get_fets();       endfunction
    virtual function int  get_cb();         return fw_get_cb();         endfunction
    virtual function int  get_fw_state();   return top.u_mcu.fw_state_v; endfunction

    virtual function bit  get_dsg_pin();    return dsg_en === 1'b1; endfunction
    virtual function bit  get_chg_pin();    return chg_en === 1'b1; endfunction
    virtual function int  get_afe_cb_reg(); return int'(top.u_board.u_afe.regs[8'h98]); endfunction
    virtual function int  get_afe_cuv_thr();
      return int'({top.u_board.u_afe.regs[8'h91], top.u_board.u_afe.regs[8'h90]});
    endfunction
    virtual function int  get_afe_ocd_thr();
      return int'({top.u_board.u_afe.regs[8'h95], top.u_board.u_afe.regs[8'h94]});
    endfunction
    virtual function real get_i_act();      return i_act; endfunction

  endclass : bq_proxy_impl

  bq_proxy_impl proxy;

  initial begin
    proxy = new("bq_proxy");
    uvm_config_db#(bq_proxy)::set(null, "*", "bq_proxy", proxy);
  end

endmodule : bq_bridge
