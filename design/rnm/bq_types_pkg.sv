`timescale 1ns/1ps
//======================================================================
// bq_types_pkg -- RNM net types for the virtual 6S BMS board.
//
// isense_node carries the shunt-sense voltage as a USER-DEFINED
// NETTYPE with sum resolution (UVM-MS 1.0, 4.2.3.2): the DC/DC
// switching-ripple interferer shares the net with the shunt model.
//======================================================================
package bq_types_pkg;

  function automatic real sum_res(input real drivers[]);
    real total = 0.0;
    foreach (drivers[i]) total += drivers[i];
    return total;
  endfunction

  nettype real isense_node with sum_res;

endpackage : bq_types_pkg
