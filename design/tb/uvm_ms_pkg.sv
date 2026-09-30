//----------------------------------------------------------------------
// PROVENANCE (this header block is the only text added to the source below)
//
// Reproduced from UVM-MS 1.0 (Accellera, January 2025), Annex A.1
// (normative), "uvm_ms_pkg.sv".  Annex A is the UVM-MS library: the
// standard prints it in full rather than shipping it separately, and this
// file is that listing verbatim, comments included.
//
// There is no UVM-MS package in uvm-core or in the iverilog install; this
// file is where uvm_ms_proxy comes from.
//----------------------------------------------------------------------

// ==================================================
// Proxy class to be extended in the MS Bridge module.
// It allows UVM components to access proxy API by
// passing a handle to the proxy instance via uvm_config_db.
// Class is declared virtual so it cannot
// be instantiated, it must be derived.
// ==================================================

`ifndef UVM_MS_PKG_SV
`define UVM_MS_PKG_SV

`include "uvm_macros.svh"

package uvm_ms_pkg;
  import uvm_pkg::*;

  /* uvm_ms_proxy provides a communication API between driver/monitor and the bridge.
   * A proxy specific to the bridge should be created inside the bridge by extending
   * uvm_ms_proxy and then implementing the API functions accordingly.
   */

  virtual class uvm_ms_proxy;
    string name;

    function new(string name="uvm_ms_proxy");
      this.name = name;
    endfunction

    // Example prototype for push/pull functions to core
    // This function should be added to a derived class and NOT to the uvm_ms_proxy class
    // virtual function void push(input real ampl, bias, freq, bit enable);
    //   `uvm_warning("proxy","Function push not implemented")
    // endfunction
    // virtual function void pull(output real ampl, bias, freq, bit enable);
    //   `uvm_warning("proxy","Function pull not implemented")
    // endfunction

  endclass : uvm_ms_proxy

endpackage : uvm_ms_pkg

`endif
