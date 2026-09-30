`timescale 1ns/1ps
//======================================================================
// bq_pkg -- the UVM-MS environment for the virtual 6S BMS board.
//
//   bq_item        pack scenario + captured host/AFE/analog snapshot
//   bq_driver      applies a scenario through the MS proxy, watches
//                  the FET pins while control loops run, captures
//   bq_scoreboard  two-pass white-box prediction; checks BOTH sides
//                  of the I2C boundary against it (host mirrors AND
//                  AFE registers), the FET pins, the analog loop-back,
//                  the balancing target, and the threshold registers
//                  the host must have written over the bus
//   bq_env         sequencer + driver + scoreboard
//======================================================================
package bq_pkg;

  import uvm_pkg::*;
  import uvm_ms_pkg::*;
  import bq_proxy_pkg::*;
  `include "uvm_macros.svh"

  // host policy constants (mirror fw/firmware.c)
  localparam int CUV_MV = 2800, COV_MV = 4250, OCD_MA = 3000;
  localparam int BAL_START_MV = 50;
  // AFE model constants (mirror rnm/bq76952_rnm.sv)
  localparam int VBAL_DROOP_MV = 40;
  localparam int OT_TRIP_C10   = 600;
  localparam int F_CUV = 1, F_COV = 2, F_OCD = 4, F_OT = 8;

  //====================================================================
  // bq_item
  //====================================================================
  class bq_item extends uvm_sequence_item;

    rand int base_mv;      // common cell OCV
    rand int jit [6];      // per-cell spread, +/-8 mV
    rand int imbal_cell;   // which cell carries the imbalance
    rand int imbal_mv;     // 0 (balanced) or 70..120 (needs balancing)
    rand int iload_ma;     // commanded load
    rand int temp_c;
    rand int rint_mohm;    // per-cell internal resistance
    rand int vgt_mil;      // cell-ADC gain tolerance, per-mil
    rand int ctol_mil;     // current-gain tolerance, per-mil
    rand int coff_ma_i;    // current offset, mA
    rand bit intf_en;
    rand bit reset_faults;

    constraint c_ranges {
      base_mv    inside {[2500:4350]};
      foreach (jit[i]) jit[i] inside {[-8:8]};
      imbal_cell inside {[0:5]};
      imbal_mv   inside {0, [70:120]};
      iload_ma   inside {[0:4500]};
      temp_c     inside {[-10:80]};
      rint_mohm  inside {[5:20]};
      vgt_mil    inside {[-5:5]};
      ctol_mil   inside {[-10:10]};
      coff_ma_i  inside {[-10:10]};
    }

    // derived
    real c_r [6];          // cell OCVs, V
    real rint, iload, temp_r, vgt, ctol, coff;
    int  c_mv [6];

    // captured: host's I2C-read view
    int h_cell [6];
    int h_ma, h_t10, h_safety, h_fets, h_cb;
    // captured: AFE + analog truth
    int a_cb, a_cuv_thr, a_ocd_thr;
    int i_act_ma;
    int trip_frames;

    `uvm_object_utils(bq_item)

    function new(string name = "bq_item");
      super.new(name);
    endfunction

    function void derive();
      for (int i = 0; i < 6; i++) begin
        c_mv[i] = base_mv + jit[i] + ((i == imbal_cell) ? imbal_mv : 0);
        c_r[i]  = real'(c_mv[i]) / 1000.0;
      end
      rint   = real'(rint_mohm) / 1000.0;
      iload  = real'(iload_ma)  / 1000.0;
      temp_r = real'(temp_c);
      vgt    = real'(vgt_mil)   / 1000.0;
      ctol   = real'(ctol_mil)  / 1000.0;
      coff   = real'(coff_ma_i);
    endfunction

    function void post_randomize();
      derive();
    endfunction

    function string convert2string();
      return $sformatf("base=%0dmV imbal=%0dmV@c%0d iload=%0dmA T=%0dC rint=%0dmR vgt=%0d ctol=%0d intf=%0b rst=%0b",
                       base_mv, imbal_mv, imbal_cell + 1, iload_ma, temp_c,
                       rint_mohm, vgt_mil, ctol_mil, intf_en, reset_faults);
    endfunction

  endclass : bq_item

  typedef uvm_sequencer#(bq_item) bq_sequencer;

  //====================================================================
  // bq_driver
  //====================================================================
  class bq_driver extends uvm_driver#(bq_item);

    `uvm_component_utils(bq_driver)

    bq_proxy proxy;
    uvm_analysis_port#(bq_item) ap;

    int fw_state_now;
    covergroup cg_fwstate;
      option.per_instance = 1;
      cp_state: coverpoint fw_state_now {
        bins config_ = {1};
        bins poll    = {2};
        bins wait_   = {4};
      }
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
      cg_fwstate = new();
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(bq_proxy)::get(this, "", "bq_proxy", proxy))
        `uvm_fatal("NOPROXY", "bq_proxy not found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
      bq_item it;
      forever begin
        seq_item_port.get_next_item(it);
        drive_scenario(it);
        ap.write(it);
        seq_item_port.item_done();
      end
    endtask

    task drive_scenario(bq_item it);
      bit polling = 1;

      `uvm_info("DRV", {"scenario: ", it.convert2string()}, UVM_LOW)

      proxy.push_scenario(it.c_r[0], it.c_r[1], it.c_r[2],
                          it.c_r[3], it.c_r[4], it.c_r[5],
                          it.rint, it.iload, it.temp_r,
                          it.vgt, it.ctol, it.coff, it.intf_en);
      proxy.fw_config(it.reset_faults ? 1 : 0);

      fork
        while (polling) begin
          fw_state_now = proxy.get_fw_state();
          cg_fwstate.sample();
          #50000;                     // 50 us
        end
      join_none

      // 8 host control loops: config write-out, AFE reaction,
      // balancing decision, everything steady by the last one
      it.trip_frames = -1;
      for (int f = 0; f < 8; f++) begin
        proxy.wait_frame_done();
        if (it.trip_frames < 0 && !proxy.get_dsg_pin()) it.trip_frames = f;
      end
      polling = 0;

      for (int i = 0; i < 6; i++) it.h_cell[i] = proxy.get_cell_mv(i);
      it.h_ma      = proxy.get_ma();
      it.h_t10     = proxy.get_t_c10();
      it.h_safety  = proxy.get_safety();
      it.h_fets    = proxy.get_fets();
      it.h_cb      = proxy.get_cb();
      it.a_cb      = proxy.get_afe_cb_reg();
      it.a_cuv_thr = proxy.get_afe_cuv_thr();
      it.a_ocd_thr = proxy.get_afe_ocd_thr();
      it.i_act_ma  = $rtoi(proxy.get_i_act() * 1000.0 + 0.5);
    endtask

  endclass : bq_driver

  //====================================================================
  // bq_scoreboard
  //====================================================================
  class bq_scoreboard extends uvm_subscriber#(bq_item);

    `uvm_component_utils(bq_scoreboard)

    int n_scen = 0, n_fail = 0;

    int cov_base, cov_iload, cov_temp, cov_imbal, cov_intf;
    int cov_safety, cov_cb_on, cov_dsg, cov_chg;

    covergroup cg_scenario;
      option.per_instance = 1;
      cp_vband : coverpoint cov_base {
        bins uv   = {[2500:2750]};
        bins low  = {[3100:3500]};
        bins nom  = {[3501:3900]};
        bins high = {[3901:4100]};
        bins ov   = {[4280:4350]};
      }
      cp_iband : coverpoint cov_iload {
        bins idle   = {[0:100]};
        bins normal = {[101:1800]};
        bins high   = {[1801:2500]};
        bins oc     = {[3200:4500]};
      }
      cp_tband : coverpoint cov_temp {
        bins cold = {[-10:5]};
        bins nom  = {[6:50]};
        bins ot   = {[62:80]};
      }
      cp_imbal : coverpoint cov_imbal {
        bins balanced   = {0};
        bins imbalanced = {[70:120]};
      }
      cp_intf   : coverpoint cov_intf   { bins off = {0}; bins on = {1}; }
      cp_safety : coverpoint cov_safety {
        bins none = {0};
        bins cuv  = {1};
        bins cov_ = {2};
        bins ocd  = {4};
        bins ot   = {8};
      }
      cp_cb  : coverpoint cov_cb_on { bins off = {0}; bins on = {1}; }
      cp_dsg : coverpoint cov_dsg   { bins off = {0}; bins on = {1}; }
      cp_chg : coverpoint cov_chg   { bins off = {0}; bins on = {1}; }
      x_i_dsg  : cross cp_iband, cp_dsg;
      x_v_dsg  : cross cp_vband, cp_dsg;
      x_v_chg  : cross cp_vband, cp_chg;
      x_imb_cb : cross cp_imbal, cp_cb;
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      cg_scenario = new();
    endfunction

    // what the AFE will report for cell i at pack current i_a, mV
    function int f_cell_mv(bq_item t, int i, real i_a, bit balancing);
      real v;
      v = (t.c_r[i] - i_a * t.rint) * (1.0 + t.vgt);
      if (balancing) v = v - real'(VBAL_DROOP_MV) / 1000.0;
      return $rtoi(v * 1000.0 + 0.5);
    endfunction

    function int f_i_ma(bq_item t, real i_a);
      return $rtoi(i_a * 1000.0 * (1.0 + t.ctol) + t.coff + 0.5);
    endfunction

    function void write(bq_item t);
      int  exp_flags, exp_cb, exp_cell [6];
      int  mn, mx, mxi, delta, i_meas;
      bit  exp_dsg, exp_chg, skip_prot, skip_cb, fail = 0;
      real i_final;
      int  tol_cell, tol_ma;

      n_scen++;

      //--- pass 1: assume the discharge path is closed ----------------
      mn = 99999; mx = -1; mxi = 0;
      for (int i = 0; i < 6; i++) begin
        int v;
        v = f_cell_mv(t, i, t.iload, 0);
        if (v < mn) mn = v;
        if (v > mx) begin mx = v; mxi = i; end
      end
      delta  = mx - mn;
      i_meas = f_i_ma(t, t.iload);

      exp_flags = 0;
      if (mn < CUV_MV)              exp_flags |= F_CUV;
      if (mx > COV_MV)              exp_flags |= F_COV;
      if (i_meas > OCD_MA)          exp_flags |= F_OCD;
      if (t.temp_c * 10 > OT_TRIP_C10) exp_flags |= F_OT;

      exp_dsg = !(exp_flags & (F_CUV | F_OCD | F_OT));
      exp_chg = !(exp_flags & (F_COV | F_OT));

      skip_prot = 0;
      if (mn > CUV_MV - 30 && mn < CUV_MV + 30)                   skip_prot = 1;
      if (mx > COV_MV - 30 && mx < COV_MV + 30)                   skip_prot = 1;
      if (i_meas > OCD_MA - (t.intf_en ? 400 : 150) &&
          i_meas < OCD_MA + (t.intf_en ? 400 : 150))              skip_prot = 1;
      if (t.temp_c >= 58 && t.temp_c <= 62)                       skip_prot = 1;

      // balancing: host bleeds the highest cell when the spread
      // exceeds 50 mV and no fault is active
      exp_cb  = (exp_flags == 0 && delta > BAL_START_MV) ? (1 << mxi) : 0;
      skip_cb = (delta > 40 && delta < 65);   // hysteresis band

      //--- pass 2: final values after the FET decision ----------------
      i_final = exp_dsg ? t.iload : 0.0;
      for (int i = 0; i < 6; i++)
        exp_cell[i] = f_cell_mv(t, i, i_final, exp_cb[i] === 1'b1 ? 1'b1 : 1'b0);

      tol_cell = 5;
      tol_ma   = t.intf_en ? 300 : 20;

      //--- measurement checks (host mirrors, read over I2C) -----------
      // gated on skip_prot: in a threshold band the FET outcome (and
      // with it the sag) is legitimately either way
      if (!skip_prot) for (int i = 0; i < 6; i++) begin
        bit cbi;
        cbi = ((exp_cb >> i) & 1) == 1;
        if (skip_cb && cbi) continue;
        if (t.h_cell[i] > exp_cell[i] + tol_cell ||
            t.h_cell[i] < exp_cell[i] - tol_cell) begin
          fail = 1;
          `uvm_error("SB", $sformatf("cell%0d: host read %0d mV, expected %0d +/- %0d (%s)",
                     i + 1, t.h_cell[i], exp_cell[i], tol_cell, t.convert2string()))
        end
      end
      if (!skip_prot &&
          (t.h_ma > f_i_ma(t, i_final) + tol_ma ||
           t.h_ma < f_i_ma(t, i_final) - tol_ma)) begin
        fail = 1;
        `uvm_error("SB", $sformatf("current: host read %0d mA, expected %0d +/- %0d (%s)",
                   t.h_ma, f_i_ma(t, i_final), tol_ma, t.convert2string()))
      end
      if (t.h_t10 > t.temp_c * 10 + 3 || t.h_t10 < t.temp_c * 10 - 3) begin
        fail = 1;
        `uvm_error("SB", $sformatf("temp: host read %0.1f C, true %0d C", real'(t.h_t10) / 10.0, t.temp_c))
      end

      //--- config-integrity check: the thresholds the host wrote must
      //    be what the AFE's protection engine is really using --------
      if (t.a_cuv_thr != CUV_MV || t.a_ocd_thr != OCD_MA) begin
        fail = 1;
        `uvm_error("SB", $sformatf("AFE thresholds CUV=%0d OCD=%0d -- host config never arrived over I2C",
                   t.a_cuv_thr, t.a_ocd_thr))
      end

      //--- protection + loop-back checks ------------------------------
      if (!skip_prot) begin
        if (t.h_safety != exp_flags) begin
          fail = 1;
          `uvm_error("SB", $sformatf("Safety Status A = 0x%0h, expected 0x%0h (%s)",
                     t.h_safety, exp_flags, t.convert2string()))
        end
        if (t.h_fets != {30'b0, exp_chg, exp_dsg}) begin
          fail = 1;
          `uvm_error("SB", $sformatf("FET status = 0x%0h, expected dsg=%0b chg=%0b",
                     t.h_fets, exp_dsg, exp_chg))
        end
        if (exp_dsg) begin
          if (t.i_act_ma > t.iload_ma + 1 || t.i_act_ma < t.iload_ma - 1) begin
            fail = 1;
            `uvm_error("SB", $sformatf("shunt current %0d mA, commanded %0d mA with DSG closed",
                       t.i_act_ma, t.iload_ma))
          end
        end
        else if (t.i_act_ma != 0) begin
          fail = 1;
          `uvm_error("SB", $sformatf("DSG open but %0d mA still flows -- loop-back broken", t.i_act_ma))
        end
        if ((exp_flags & F_OCD) && t.reset_faults &&
            (t.trip_frames < 0 || t.trip_frames > 3)) begin
          fail = 1;
          `uvm_error("SB", $sformatf("OCD trip took %0d host loops (limit 3)", t.trip_frames))
        end
      end

      //--- balancing checks -------------------------------------------
      if (!skip_cb && !skip_prot) begin
        if (t.h_cb != exp_cb || t.a_cb != exp_cb) begin
          fail = 1;
          `uvm_error("SB", $sformatf("CB host=0x%0h afe=0x%0h, expected 0x%0h (highest cell %0d)",
                     t.h_cb, t.a_cb, exp_cb, mxi + 1))
        end
        if (exp_cb != 0)
          `uvm_info("SB", $sformatf("BALANCING CLOSED-LOOP: host targeted cell %0d over I2C; its reading droops the predicted %0d mV",
                    mxi + 1, VBAL_DROOP_MV), UVM_LOW)
      end

      if ((exp_flags & F_OCD) && !t.h_fets[0] && !skip_prot)
        `uvm_info("SB", $sformatf("PROTECTION CLOSED-LOOP: AFE tripped OCD in %0d host loop(s); current now %0d mA",
                  t.trip_frames < 0 ? 0 : t.trip_frames, t.i_act_ma), UVM_LOW)

      if (fail) n_fail++;

      `uvm_info("SB", $sformatf("scen %0d: %s | c1=%0d/%0d cmax=%0d I=%0d T=%0.1f ss=0x%0h/0x%0h fets=0x%0h cb=0x%0h/0x%0h i_act=%0d %s",
                n_scen, t.convert2string(), t.h_cell[0], exp_cell[0], mx,
                t.h_ma, real'(t.h_t10) / 10.0, t.h_safety, exp_flags,
                t.h_fets, t.h_cb, exp_cb, t.i_act_ma,
                fail ? "FAIL" : ((skip_prot || skip_cb) ? "OK(band)" : "OK")), UVM_LOW)

      //--- cover ------------------------------------------------------
      cov_base   = t.base_mv;
      cov_iload  = t.iload_ma;
      cov_temp   = t.temp_c;
      cov_imbal  = t.imbal_mv;
      cov_intf   = t.intf_en;
      cov_safety = t.h_safety;
      cov_cb_on  = (t.h_cb != 0);
      cov_dsg    = t.h_fets[0];
      cov_chg    = t.h_fets[1];
      cg_scenario.sample();
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("SB", $sformatf("scenarios=%0d failed=%0d", n_scen, n_fail), UVM_LOW)
    endfunction

  endclass : bq_scoreboard

  //====================================================================
  // bq_env
  //====================================================================
  class bq_env extends uvm_env;

    `uvm_component_utils(bq_env)

    bq_sequencer  sqr;
    bq_driver     drv;
    bq_scoreboard sb;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sqr = bq_sequencer ::type_id::create("sqr", this);
      drv = bq_driver    ::type_id::create("drv", this);
      sb  = bq_scoreboard::type_id::create("sb",  this);
    endfunction

    function void connect_phase(uvm_phase phase);
      drv.seq_item_port.connect(sqr.seq_item_export);
      drv.ap.connect(sb.analysis_export);
    endfunction

  endclass : bq_env

  //====================================================================
  // sequences
  //====================================================================
  class smoke_seq extends uvm_sequence#(bq_item);
    `uvm_object_utils(smoke_seq)
    function new(string name = "smoke_seq"); super.new(name); endfunction
    task body();
      bq_item it;
      it = bq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with { base_mv == 3700; imbal_mv == 0;
                                 jit[0] == 0; jit[1] == 0; jit[2] == 0;
                                 jit[3] == 0; jit[4] == 0; jit[5] == 0;
                                 iload_ma == 1000; temp_c == 25;
                                 rint_mohm == 12; vgt_mil == 0;
                                 ctol_mil == 0; coff_ma_i == 0;
                                 intf_en == 0; reset_faults == 1; })
        `uvm_fatal("SEQ", "randomize failed")
      finish_item(it);
    endtask
  endclass : smoke_seq

  class corner_seq extends uvm_sequence#(bq_item);
    `uvm_object_utils(corner_seq)
    int n = 4;
    function new(string name = "corner_seq"); super.new(name); endfunction
    task body();
      bq_item it;
      repeat (n) begin
        it = bq_item::type_id::create("it");
        start_item(it);
        if (!it.randomize() with { base_mv inside {[3150:4050]};
                                   imbal_mv == 0;
                                   iload_ma inside {[0:2500]};
                                   temp_c inside {[0:50]};
                                   intf_en == 0; reset_faults == 1; })
          `uvm_fatal("SEQ", "randomize failed")
        finish_item(it);
      end
    endtask
  endclass : corner_seq

  class prot_seq extends uvm_sequence#(bq_item);
    `uvm_object_utils(prot_seq)
    function new(string name = "prot_seq"); super.new(name); endfunction
    task body();
      bq_item it;
      // cell undervoltage
      it = bq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with { base_mv == 2650; imbal_mv == 0;
                                 iload_ma == 300; temp_c == 25;
                                 intf_en == 0; reset_faults == 1; })
        `uvm_fatal("SEQ", "randomize failed")
      finish_item(it);
      // cell overvoltage
      it = bq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with { base_mv == 4320; imbal_mv == 0;
                                 iload_ma == 0; temp_c == 25;
                                 intf_en == 0; reset_faults == 1; })
        `uvm_fatal("SEQ", "randomize failed")
      finish_item(it);
      // overcurrent (AFE trips + latches; loop-back stops the amps)
      it = bq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with { base_mv == 3700; imbal_mv == 0;
                                 iload_ma == 4200; temp_c == 25;
                                 intf_en == 0; reset_faults == 1; })
        `uvm_fatal("SEQ", "randomize failed")
      finish_item(it);
      // overtemperature
      it = bq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with { base_mv == 3700; imbal_mv == 0;
                                 iload_ma == 800; temp_c == 70;
                                 intf_en == 0; reset_faults == 1; })
        `uvm_fatal("SEQ", "randomize failed")
      finish_item(it);
      // imbalance: host must balance the right cell over I2C
      it = bq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with { base_mv == 3700; imbal_mv == 90;
                                 imbal_cell == 3;
                                 jit[0] == 0; jit[1] == 0; jit[2] == 0;
                                 jit[3] == 0; jit[4] == 0; jit[5] == 0;
                                 iload_ma == 500; temp_c == 25;
                                 intf_en == 0; reset_faults == 1; })
        `uvm_fatal("SEQ", "randomize failed")
      finish_item(it);
      // DC/DC ripple on the shunt-sense net (UDN second driver)
      it = bq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with { base_mv == 3700; imbal_mv == 0;
                                 iload_ma == 1500; temp_c == 25;
                                 intf_en == 1; reset_faults == 1; })
        `uvm_fatal("SEQ", "randomize failed")
      finish_item(it);
    endtask
  endclass : prot_seq

  // hero: normal -> overload (AFE latches OCD, current really stops)
  // -> load removed + host recover write over I2C -> running again
  class hero_seq extends uvm_sequence#(bq_item);
    `uvm_object_utils(hero_seq)
    function new(string name = "hero_seq"); super.new(name); endfunction
    task body();
      bq_item it;
      it = bq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with { base_mv == 3700; imbal_mv == 0;
                                 iload_ma == 1000; temp_c == 25;
                                 rint_mohm == 12;
                                 intf_en == 0; reset_faults == 1; })
        `uvm_fatal("SEQ", "randomize failed")
      finish_item(it);
      it = bq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with { base_mv == 3700; imbal_mv == 0;
                                 iload_ma == 4200; temp_c == 25;
                                 rint_mohm == 12;
                                 intf_en == 0; reset_faults == 0; })
        `uvm_fatal("SEQ", "randomize failed")
      finish_item(it);
      it = bq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with { base_mv == 3700; imbal_mv == 0;
                                 iload_ma == 1000; temp_c == 25;
                                 rint_mohm == 12;
                                 intf_en == 0; reset_faults == 1; })
        `uvm_fatal("SEQ", "randomize failed")
      finish_item(it);
    endtask
  endclass : hero_seq

endpackage : bq_pkg
