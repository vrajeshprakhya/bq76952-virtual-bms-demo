`timescale 1ns/1ps
//======================================================================
// loadcell_rnm -- RNM model of the load cell + Wheatstone bridge.
//
// The physics that reaches the electronics:
//   vdiff = (force/CAP) * SENS_MVV*(1+tol) * vexc / 1000  +  zero_off
// with
//   * SENS_MVV: rated sensitivity in mV/V (2.00 nominal) -- the bridge
//     output is RATIOMETRIC to the excitation, which is why the HX717's
//     ratiometric conversion cancels the excitation corner almost
//     exactly (the scoreboard proves that, it doesn't assume it)
//   * sens_tol: this board's bridge tolerance, pushed per scenario
//   * zero_off: bridge zero imbalance, also ratiometric (scaled from
//     its 5.0 V reference value)
//   * mechanical overload stop at 150% of capacity
//   * fault modes: 1 = signal wire break (the + sense line floats
//     toward excitation: a huge positive differential that rails the
//     ADC), 2 = bridge short (vdiff = 0 regardless of force)
//
// Output is a bridge_node UDN: the mains interferer sums onto it.
//======================================================================
module loadcell_rnm import lc_types_pkg::*; #(
  parameter real CAP_G    = 5000.0,  // rated capacity, grams
  parameter real SENS_MVV = 2.00,    // mV/V at capacity
  parameter real OVER_LIM = 1.50     // mechanical stop, x capacity
)(
  input  wreal       force_g,     // physical stimulus
  input  wreal       vexc,        // bridge excitation (= HX717 AVDD)
  input  wreal       sens_tol,    // e.g. +0.02 for +2%
  input  wreal       zero_off,    // bridge zero offset, V at 5 V exc
  input  logic [1:0] fault_mode,  // 0 normal, 1 wire break, 2 short
  output bridge_node vdiff        // differential output (UDN, summing)
);

  real v = 0.0;
  assign vdiff = v;

  always @(force_g or vexc or sens_tol or zero_off or fault_mode) begin
    real fclamp, vsig;
    case (fault_mode)
      2'd1: v = 0.40 * vexc;              // + sense floats up: rails ADC
      2'd2: v = 0.0;                      // shorted bridge
      default: begin
        fclamp = force_g;
        if (fclamp >  OVER_LIM * CAP_G) fclamp =  OVER_LIM * CAP_G;
        if (fclamp < -OVER_LIM * CAP_G) fclamp = -OVER_LIM * CAP_G;
        vsig = (fclamp / CAP_G) * (SENS_MVV * (1.0 + sens_tol)) / 1000.0 * vexc;
        v    = vsig + zero_off * (vexc / 5.0);
      end
    endcase
  end

endmodule : loadcell_rnm
