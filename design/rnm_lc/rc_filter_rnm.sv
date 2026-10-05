`timescale 1ns/1ps
//======================================================================
// rc_filter_rnm -- the board's differential RC anti-alias filter
// between the bridge and the HX717 inputs (the Plimsoll board's
// R/C pair, tau ~ 100 us), first-order discrete-time.
//
// Input is the summed bridge_node UDN (bridge + interferer); output is
// the settled differential voltage the ADC actually samples.
//======================================================================
module rc_filter_rnm import lc_types_pkg::*; #(
  parameter int  TS_NS = 5000,      // 5 us update
  parameter real ALPHA = 0.0488     // 1 - exp(-5/100)
)(
  input  bridge_node vin,
  output wreal       vout
);

  real v = 0.0;
  assign vout = v;

  always #(TS_NS) begin
    v = v + (vin - v) * ALPHA;
  end

endmodule : rc_filter_rnm
