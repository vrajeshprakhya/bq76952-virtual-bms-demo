`timescale 1ns/1ps
//======================================================================
// mcu_virtual -- the virtual STM32G0B1 host: a 20 MHz tick stepping
// the REAL firmware (fw/firmware.c) through DPI.  The firmware's only
// pins are the I2C pair; SDA is open-drain, so the shim exposes a
// pull-low output and reads back the resolved bus.
//
// Renode swap-in point: replace with an STM32G0B1 machine whose I2C
// peripheral drives the same two pins; the host BMS logic ports
// unchanged.
//======================================================================
module mcu_virtual #(
  parameter int TICK_NS = 50
)(
  input  logic sda_bus,               // resolved open-drain bus
  output logic scl,
  output logic sda_pull,              // 1 = master pulls SDA low
  output logic frame_done             // one-tick pulse per control loop
);

  `include "fw_dpi.svh"

  int fw_state_v = 0;                 // observed by the bridge (OOMR)

  initial begin
    scl = 1; sda_pull = 0; frame_done = 0;
    fw_set_tick_ns(TICK_NS);
  end

  always begin
    int o_scl, o_pull, o_fd, o_state;
    #(TICK_NS);
    fw_tick((sda_bus === 1'b1) ? 1 : 0, o_scl, o_pull, o_fd, o_state);
    // order matters for I2C START/STOP detection: move SDA first,
    // while SCL still holds its previous value
    sda_pull   = o_pull[0];
    scl        = o_scl[0];
    frame_done = o_fd[0];
    fw_state_v = o_state;
  end

endmodule : mcu_virtual
