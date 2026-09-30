//======================================================================
// test_lib.svh -- the test library (included by top.sv).
//======================================================================

class bq_base_test extends uvm_test;

  `uvm_component_utils(bq_base_test)

  bq_env env;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = bq_env::type_id::create("env", this);
  endfunction

  function void report_phase(uvm_phase phase);
    uvm_report_server svr = uvm_report_server::get_server();
    if (svr.get_severity_count(UVM_ERROR) == 0 &&
        svr.get_severity_count(UVM_FATAL) == 0)
      `uvm_info("TEST", "TEST-VERDICT: PASS", UVM_NONE)
    else
      `uvm_info("TEST", "TEST-VERDICT: FAIL", UVM_NONE)
  endfunction

endclass : bq_base_test

//----------------------------------------------------------------------
// smoke: one nominal operating point
//----------------------------------------------------------------------
class bq_smoke_test extends bq_base_test;

  `uvm_component_utils(bq_smoke_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    smoke_seq seq;
    phase.raise_objection(this);
    seq = smoke_seq::type_id::create("seq");
    seq.start(env.sqr);
    phase.drop_objection(this);
  endtask

endclass : bq_smoke_test

//----------------------------------------------------------------------
// regress: safe-region corners, one directed scenario per protection
// region + balancing + ripple, then the closed-loop hero sequence.
// +n_corners=<N> overrides the corner count.
//----------------------------------------------------------------------
class bq_regress_test extends bq_base_test;

  `uvm_component_utils(bq_regress_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    corner_seq cseq;
    prot_seq   pseq;
    hero_seq   hseq;
    int n = 4;

    phase.raise_objection(this);
    void'($value$plusargs("n_corners=%d", n));

    cseq = corner_seq::type_id::create("cseq");
    cseq.n = n;
    cseq.start(env.sqr);

    pseq = prot_seq::type_id::create("pseq");
    pseq.start(env.sqr);

    hseq = hero_seq::type_id::create("hseq");
    hseq.start(env.sqr);

    phase.drop_objection(this);
  endtask

endclass : bq_regress_test
