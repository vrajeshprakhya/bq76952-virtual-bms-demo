`timescale 1ns/1ps
//======================================================================
// bq_proxy_pkg -- the ABSTRACT half of the MS Proxy (UVM-MS 4.2.1)
// for the virtual 6S BMS board.  Concrete impl in bq_bridge.sv.
//======================================================================
package bq_proxy_pkg;

  import uvm_pkg::*;
  import uvm_ms_pkg::*;
  `include "uvm_macros.svh"

  virtual class bq_proxy extends uvm_ms_proxy;

    function new(string name = "bq_proxy");
      super.new(name);
    endfunction

    // 6.2.4 push analog control: pack state + board build.
    // Six scalar cell arguments, not an unpacked array: an array
    // formal on this virtual method arrived empty (see README).
    pure virtual function void push_scenario(input real c1, input real c2,
                                             input real c3, input real c4,
                                             input real c5, input real c6,
                                             input real rint,
                                             input real iload,
                                             input real temp_c,
                                             input real vgain_tol,
                                             input real ctol,
                                             input real coff_ma,
                                             input bit  intf_en);

    // host firmware control
    pure virtual function void fw_config(input int reset_faults);

    // handshake: block until the host completes a control loop
    pure virtual task wait_frame_done();

    // 6.2.6 pull: what the HOST believes (its I2C-read mirrors)
    pure virtual function int  get_cell_mv(input int idx);
    pure virtual function int  get_ma();
    pure virtual function int  get_t_c10();
    pure virtual function int  get_safety();
    pure virtual function int  get_fets();
    pure virtual function int  get_cb();
    pure virtual function int  get_fw_state();

    // 6.2.6 pull: what the AFE and the analog domain really hold
    pure virtual function bit  get_dsg_pin();
    pure virtual function bit  get_chg_pin();
    pure virtual function int  get_afe_cb_reg();
    pure virtual function int  get_afe_cuv_thr();
    pure virtual function int  get_afe_ocd_thr();
    pure virtual function real get_i_act();

  endclass : bq_proxy

endpackage : bq_proxy_pkg
