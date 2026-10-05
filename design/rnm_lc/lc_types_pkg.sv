`timescale 1ns/1ps
//======================================================================
// lc_types_pkg -- RNM net types for the virtual load-cell board.
//
// bridge_node carries the load cell's DIFFERENTIAL output voltage as a
// single real, as a USER-DEFINED NETTYPE whose resolution function sums
// all driver contributions (UVM-MS 1.0 clause 4.2.3.2).  The mains-hum
// interferer shares this net with the bridge model; a broken bridge
// wire is simply a different contribution from the sensor driver.
//======================================================================
package lc_types_pkg;

  function automatic real sum_res(input real drivers[]);
    real total = 0.0;
    foreach (drivers[i]) total += drivers[i];
    return total;
  endfunction

  nettype real bridge_node with sum_res;

endpackage : lc_types_pkg
