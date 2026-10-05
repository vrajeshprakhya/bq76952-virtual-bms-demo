`timescale 1ns/1ps
//======================================================================
// pin_bridge -- the GENERIC SV half of the co-simulation bridge.
// Protocol-agnostic: N_OUT firmware-driven pins in, N_IN board-driven
// pins out, as vectors.  The pin map (bit 0 = SCLK, bit 1 = CS, ...)
// is the instantiating top's business; this module just moves levels
// and time.  Same contract as every bridge in this repo: board time
// advances only on 'A' commands, every command is acknowledged with
// the freshly settled input pins plus the ALERT level.
//======================================================================
module pin_bridge #(
  parameter int PORT      = 43604,
  parameter int N_OUT     = 1,
  parameter int N_IN      = 1,
  parameter int OUT_RESET = 0        // pin levels before first command
)(
  input  logic [N_IN-1:0]  in_pins,
  input  logic             alert,
  output logic [N_OUT-1:0] out_pins
);

  import "DPI-C" function int brg_init(input int port);
  import "DPI-C" function int brg_next(input int in_now,
                                       input int alert_now,
                                       output int out_o,
                                       output int ns_o);

  int in_q, al_q;

  initial begin
    out_pins = N_OUT'(OUT_RESET);
    if (brg_init(PORT) != 0)
      $fatal(1, "[pin_bridge] cannot listen on port %0d", PORT);
    #1;
    in_q = int'(in_pins);
    al_q = (alert === 1'b1);
    forever begin
      int t, o, ns;
      t = brg_next(in_q, al_q, o, ns);
      if (t == 0) begin
        out_pins = N_OUT'(o);
        #1;
      end
      else if (t == 1) begin
        #(ns);
      end
      else begin
        $display("[pin_bridge] client finished at t=%0t", $time);
        $finish;
      end
      in_q = int'(in_pins);
      al_q = (alert === 1'b1);
    end
  end

endmodule : pin_bridge
