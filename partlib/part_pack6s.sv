`timescale 1ns/1ps
//======================================================================
// part_pack6s -- the six-cell stack behind connector J1, as node
// voltages on the connector's pins (B1..B6 above B0 = ground). Every
// cell sags by i_pack * RINT while current flows; i_pack is the
// current the generated power path says is actually flowing.
//======================================================================
module part_pack6s #(
  parameter real OCV  = 3.7,      // per-cell open-circuit voltage
  parameter real RINT = 0.012     // per-cell internal resistance, ohm
) (
  input  real i_pack,
  output real n1, n2, n3, n4, n5, n6
);
  real vcell;
  assign vcell = OCV - i_pack * RINT;
  assign n1 = 1.0 * vcell;
  assign n2 = 2.0 * vcell;
  assign n3 = 3.0 * vcell;
  assign n4 = 4.0 * vcell;
  assign n5 = 5.0 * vcell;
  assign n6 = 6.0 * vcell;
endmodule : part_pack6s
