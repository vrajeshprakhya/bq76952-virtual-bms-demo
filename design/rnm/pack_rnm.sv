`timescale 1ns/1ps
//======================================================================
// pack_rnm -- 6S li-ion pack + load + shunt, with the protection
// loop-back: load current flows only while the AFE's DSG FET is
// closed, and every cell sags by i * rint while it does.
//
// The shunt-sense output is an isense_node UDN so the DC/DC ripple
// interferer can sum onto it.
//======================================================================
module pack_rnm import bq_types_pkg::*; #(
  parameter real RSHUNT = 0.001      // ohm
)(
  input  wreal       p_c1, p_c2, p_c3, p_c4, p_c5, p_c6,  // cell OCVs
  input  wreal       rint,          // per-cell internal resistance
  input  wreal       i_load,        // commanded load current, A
  input  logic       dsg_en,        // AFE's discharge FET
  output wreal       vc1, vc2, vc3, vc4, vc5, vc6,        // terminals
  output isense_node v_shunt,       // shunt sense voltage (UDN)
  output wreal       i_act          // actual pack current
);

  // scalars, not an unpacked array: a continuous assign fed from an
  // array element missed the procedural updates here (cells then read
  // 0 V and the AFE's CUV latched) -- found by the smoke test
  real ia = 0.0, vs = 0.0;
  real v0 = 0.0, v1 = 0.0, v2 = 0.0, v3 = 0.0, v4 = 0.0, v5 = 0.0;

  assign i_act   = ia;
  assign v_shunt = vs;
  assign vc1 = v0; assign vc2 = v1; assign vc3 = v2;
  assign vc4 = v3; assign vc5 = v4; assign vc6 = v5;

  always @(p_c1 or p_c2 or p_c3 or p_c4 or p_c5 or p_c6
           or rint or i_load or dsg_en) begin
    ia = (dsg_en === 1'b1) ? i_load : 0.0;
    vs = ia * RSHUNT;
    v0 = p_c1 - ia * rint;
    v1 = p_c2 - ia * rint;
    v2 = p_c3 - ia * rint;
    v3 = p_c4 - ia * rint;
    v4 = p_c5 - ia * rint;
    v5 = p_c6 - ia * rint;
  end

endmodule : pack_rnm
