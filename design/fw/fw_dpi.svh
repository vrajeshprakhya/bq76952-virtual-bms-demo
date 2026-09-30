//----------------------------------------------------------------------
// fw_dpi.svh -- DPI surface of the host BMS firmware (fw/firmware.c).
// `include INSIDE a module (xezim wants DPI imports in module scope).
//----------------------------------------------------------------------
import "DPI-C" function void fw_set_tick_ns(input int t);
import "DPI-C" function void fw_configure(input int reset_faults,
                                          input int run);
import "DPI-C" function void fw_tick(input  int sda_in,
                                     output int scl,
                                     output int sda_pull,
                                     output int frame_done,
                                     output int fw_state);
import "DPI-C" function int  fw_get_cell_mv(input int idx);
import "DPI-C" function int  fw_get_ma();
import "DPI-C" function int  fw_get_t_c10();
import "DPI-C" function int  fw_get_safety();
import "DPI-C" function int  fw_get_fets();
import "DPI-C" function int  fw_get_cb();
import "DPI-C" function int  fw_get_delta();
import "DPI-C" function int  fw_get_loop_count();
