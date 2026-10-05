`timescale 1ns/1ps
//======================================================================
// mains_interferer -- second driver on the bridge output net.
//
// 50 Hz mains hum picked up on the microvolt-level bridge wiring,
// +/-AMPL triangle.  Shares the bridge_node UDN with the load cell;
// the nettype's sum resolution combines the contributions (UVM-MS
// 4.2.3.2).  Contributes exactly 0.0 when disabled.
//======================================================================
module mains_interferer import lc_types_pkg::*; #(
  parameter real AMPL      = 2.0e-6,      // V
  parameter real PERIOD_NS = 20.0e6,      // 50 Hz
  parameter int  TS_NS     = 100000       // 100 us update
)(
  input  logic       en,
  output bridge_node y
);

  real v = 0.0;
  assign y = v;

  always #(TS_NS) begin
    real t, ph, a;
    if (en) begin
      t  = $realtime;
      ph = t / PERIOD_NS;
      ph = ph - $rtoi(ph);
      a  = ph - 0.5;
      if (a < 0.0) a = -a;
      v  = AMPL * (4.0 * a - 1.0);
    end
    else v = 0.0;
  end

endmodule : mains_interferer
