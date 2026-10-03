`timescale 1ns/1ps
//======================================================================
// renode_bridge2 -- v2 (virtual-time quantum coupling) SV half.
// Identical loop to v1 with one addition: the ack carries the board's
// ALERT level, so Renode can raise a real interrupt on the emulated
// CPU.  The 'A' commands now arrive from Renode's quantum engine (CPU
// virtual time), not from firmware-declared delays.
//======================================================================
module renode_bridge2 #(
  parameter int PORT = 43602
)(
  input  logic sda_bus,
  input  logic alert,
  output logic scl,
  output logic sda_pull
);

  import "DPI-C" function int br2_init(input int port);
  import "DPI-C" function int br2_next(input int sda_now,
                                       input int alert_now,
                                       output int scl_o,
                                       output int sda_o,
                                       output int ns_o);

  int sda_q, al_q;

  initial begin
    scl = 1; sda_pull = 0;
    if (br2_init(PORT) != 0)
      $fatal(1, "[renode_bridge2] cannot listen on port %0d", PORT);
    #1;
    sda_q = (sda_bus === 1'b1);
    al_q  = (alert   === 1'b1);
    forever begin
      int t, s, d, ns;
      t = br2_next(sda_q, al_q, s, d, ns);
      if (t == 0) begin
        sda_pull = d[0];
        scl      = s[0];
        #1;
      end
      else if (t == 1) begin
        #(ns);
      end
      else begin
        $display("[renode_bridge2] firmware finished at t=%0t", $time);
        $finish;
      end
      sda_q = (sda_bus === 1'b1);
      al_q  = (alert   === 1'b1);
    end
  end

endmodule : renode_bridge2
