`timescale 1ns/1ps
//======================================================================
// renode_bridge -- the SV half of the Renode<->xezim bridge.  Replaces
// mcu_virtual: instead of a DPI tick-FSM, the MCU pins are driven by
// commands arriving over a socket from the Renode-emulated STM32, and
// xezim time advances ONLY when the firmware spends time ('A' cmds).
//======================================================================
module renode_bridge #(
  parameter int PORT = 43601
)(
  input  logic sda_bus,     // resolved open-drain bus
  output logic scl,
  output logic sda_pull     // 1 = MCU pulls SDA low
);

  import "DPI-C" function int br_init(input int port);
  import "DPI-C" function int br_next(input int sda_now,
                                      output int scl_o,
                                      output int sda_o,
                                      output int ns_o);

  int sda_q;

  initial begin
    scl = 1; sda_pull = 0;
    if (br_init(PORT) != 0)
      $fatal(1, "[renode_bridge] cannot listen on port %0d", PORT);
    #1;
    sda_q = (sda_bus === 1'b1);
    forever begin
      int t, s, d, ns;
      t = br_next(sda_q, s, d, ns);          // blocks for the SoC
      if (t == 0) begin                      // SET pins
        sda_pull = d[0];
        scl      = s[0];
        #1;                                  // let the slave settle
      end
      else if (t == 1) begin                 // ADVANCE board time
        #(ns);
      end
      else begin                             // FINISH
        $display("[renode_bridge] firmware finished at t=%0t", $time);
        $finish;
      end
      sda_q = (sda_bus === 1'b1);
    end
  end

endmodule : renode_bridge
