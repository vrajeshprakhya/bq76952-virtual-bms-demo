`timescale 1ns/1ps
//======================================================================
// ripple_interferer -- second driver on the shunt-sense net.
//
// 20 kHz DC/DC switching ripple, +/-AMPL triangle, coupled onto the
// millivolt-level shunt-sense trace (0.2 mV here = +/-200 mA of
// apparent pack current).  Shares the isense_node UDN with the shunt;
// the nettype's sum resolution combines them (UVM-MS 4.2.3.2).
//======================================================================
module ripple_interferer import bq_types_pkg::*; #(
  parameter real AMPL      = 0.0002,    // V
  parameter real PERIOD_NS = 50000.0,   // 20 kHz
  parameter int  TS_NS     = 2000
)(
  input  logic       en,
  output isense_node y
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

endmodule : ripple_interferer
