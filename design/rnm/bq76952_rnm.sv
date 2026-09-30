`timescale 1ns/1ps
//======================================================================
// bq76952_rnm -- behavioural model of a BQ76952-class battery-monitor
// AFE: its own measurement engine, its own hardware protection engine
// with HOST-PROGRAMMABLE thresholds, FET drive, cell balancing, and a
// pin-level I2C slave exposing the register map.
//
// Demo register map (BQ76952-flavoured, simplified -- documented in
// the README; the real part reaches RAM config through the 0x3E/0x3F
// subcommand + checksum protocol, which this demo flattens into
// directly writable registers):
//   0x03      Safety Status A (RO): b0 CUV, b1 COV, b2 OCD, b3 OT
//   0x14+2n   cell n+1 voltage, mV, LE (RO)
//   0x3A/3B   pack current, mA, signed LE (RO)
//   0x68/69   temperature, 0.1 C, signed LE (RO)
//   0x7F      FET status (RO): b0 DSG, b1 CHG
//   0x90..95  CUV / COV (mV) and OCD (mA) thresholds, LE (RW)
//   0x96      protection enable: b0 CUV, b1 COV, b2 OCD, b3 OT (RW)
//   0x97      FET allow: b0 DSG, b1 CHG (RW)
//   0x98      CB active cells bitmask (RW)
//   0x99      recover: write 1 clears the latched OCD (self-clearing)
//
// Behaviours captured:
//   * measurement loop every TMEAS_NS: cells to 1 mV (gain tolerance +
//     noise), pack current from the shunt-sense UDN, temperature
//   * BALANCING MEASUREMENT ARTIFACT: a cell being bled through its
//     sense line reads VBAL_DROOP lower -- a real BQ-family effect
//   * protection engine on its own cadence: CUV/COV with hysteresis +
//     recovery counting, OCD LATCHED until the host writes 0x99, OT
//   * FET outputs = protection AND host allow bits
//   * pin-level I2C slave, 7-bit address 0x08: START/STOP detection,
//     register pointer with auto-increment, burst read/write, RO
//     ranges write-protected
//======================================================================
module bq76952_rnm import bq_types_pkg::*; #(
  parameter real TMEAS_NS   = 250000.0,  // measurement + protection loop
  parameter real CELL_NOISE = 0.001,     // +/- V on each cell reading
  parameter real VBAL_DROOP = 0.040,     // V read-droop while balancing
  parameter real RSHUNT     = 0.001,     // ohm
  parameter real I_NOISE    = 5.0,       // +/- mA
  parameter int  RECOV_N    = 4          // clean cycles to clear CUV/COV/OT
)(
  // pack side
  input  wreal       vc1, vc2, vc3, vc4, vc5, vc6,   // cell terminals
  input  isense_node v_shunt,                        // shunt sense (UDN)
  input  wreal       temp_c,
  input  wreal       vgain_tol,     // cell-ADC gain tolerance
  input  wreal       ctol,          // current-gain tolerance
  input  wreal       coff_ma,       // current offset, mA
  // host side
  input  logic       scl,
  input  logic       sda_bus,       // resolved open-drain bus
  output logic       sda_pull,      // 1 = slave pulls SDA low
  // pack control
  output logic       dsg_en,
  output logic       chg_en
);

  localparam logic [6:0] I2C_ADDR = 7'h08;

  //--- register file --------------------------------------------------
  byte unsigned regs [0:255];
  int  por_defaults_done = 0;

  initial begin
    for (int i = 0; i < 256; i++) regs[i] = 8'h00;
    // datasheet-style loose defaults until the host configures
    {regs[8'h91], regs[8'h90]} = 16'(2500);
    {regs[8'h93], regs[8'h92]} = 16'(4300);
    {regs[8'h95], regs[8'h94]} = 16'(5000);
    regs[8'h96] = 8'h0F;
    regs[8'h97] = 8'h03;
    dsg_en   = 1'b1;
    chg_en   = 1'b1;
    sda_pull = 1'b0;
  end

  //--- measurement engine ---------------------------------------------
  real cells [0:5];
  int  meas_mv [0:5];
  int  meas_ma   = 0;
  int  meas_t10  = 250;

  always begin
    #(TMEAS_NS);
    // sample the cell terminals directly at conversion time (v1 copied
    // them through an always @(*) block; when that missed an update the
    // cells read 0 V and the AFE's own CUV latched DSG off -- found by
    // the smoke test's loop-back check)
    cells[0] = vc1; cells[1] = vc2; cells[2] = vc3;
    cells[3] = vc4; cells[4] = vc5; cells[5] = vc6;
    for (int i = 0; i < 6; i++) begin
      real v, n;
      n = (real'($urandom_range(0, 2000)) - 1000.0) / 1000.0 * CELL_NOISE;
      v = cells[i] * (1.0 + vgain_tol) + n;
      if (regs[8'h98][i]) v = v - VBAL_DROOP;       // balancing artifact
      meas_mv[i] = $rtoi(v * 1000.0 + 0.5);
      if (meas_mv[i] < 0) meas_mv[i] = 0;
      {regs[8'h15 + 2*i], regs[8'h14 + 2*i]} = 16'(meas_mv[i]);
    end
    begin
      real n;
      n = (real'($urandom_range(0, 2000)) - 1000.0) / 1000.0 * I_NOISE;
      meas_ma = $rtoi(v_shunt / RSHUNT * 1000.0 * (1.0 + ctol) + coff_ma + n + 0.5);
      {regs[8'h3B], regs[8'h3A]} = 16'(meas_ma);
    end
    meas_t10 = $rtoi(temp_c * 10.0 + (temp_c >= 0.0 ? 0.5 : -0.5));
    {regs[8'h69], regs[8'h68]} = 16'(meas_t10);
    run_protection();
  end

  //--- protection engine ----------------------------------------------
  int cuv_cnt = 0, cov_cnt = 0, ot_cnt = 0;

  function automatic int thr16(input byte unsigned lo_addr);
    return {regs[lo_addr + 8'd1], regs[lo_addr]};
  endfunction

  function automatic void run_protection();
    int mn, mx, cuv, cov, ocd;
    byte unsigned ss;
    mn = 99999; mx = -1;
    for (int i = 0; i < 6; i++) begin
      if (meas_mv[i] < mn) mn = meas_mv[i];
      if (meas_mv[i] > mx) mx = meas_mv[i];
    end
    cuv = thr16(8'h90); cov = thr16(8'h92); ocd = thr16(8'h94);
    ss  = regs[8'h03];

    // CUV / COV / OT: trip immediately, recover with hysteresis
    if (regs[8'h96][0] && mn < cuv)              begin ss[0] = 1'b1; cuv_cnt = 0; end
    else if (ss[0] && mn > cuv + 100)            begin
      if (++cuv_cnt >= RECOV_N)                  begin ss[0] = 1'b0; cuv_cnt = 0; end
    end else cuv_cnt = 0;

    if (regs[8'h96][1] && mx > cov)              begin ss[1] = 1'b1; cov_cnt = 0; end
    else if (ss[1] && mx < cov - 100)            begin
      if (++cov_cnt >= RECOV_N)                  begin ss[1] = 1'b0; cov_cnt = 0; end
    end else cov_cnt = 0;

    // OCD: LATCHED until the host writes the recover register
    if (regs[8'h96][2] && meas_ma > ocd)         ss[2] = 1'b1;

    if (regs[8'h96][3] && meas_t10 > 600)        begin ss[3] = 1'b1; ot_cnt = 0; end
    else if (ss[3] && meas_t10 < 550)            begin
      if (++ot_cnt >= RECOV_N)                   begin ss[3] = 1'b0; ot_cnt = 0; end
    end else ot_cnt = 0;

    regs[8'h03] = ss;
    dsg_en = !(ss[0] || ss[2] || ss[3]) && regs[8'h97][0];
    chg_en = !(ss[1] || ss[3])          && regs[8'h97][1];
    regs[8'h7F] = {6'b0, chg_en, dsg_en};
  endfunction

  //--- host register writes (side effects) ----------------------------
  function automatic void host_write(input byte unsigned addr,
                                     input byte unsigned data);
    // only the config page is writable
    if (addr >= 8'h90 && addr <= 8'h98) regs[addr] = data;
    else if (addr == 8'h99 && data[0]) begin
      regs[8'h03][2] = 1'b0;                       // clear latched OCD
    end
  endfunction

  //--- pin-level I2C slave --------------------------------------------
  typedef enum int {M_ADDR, M_WDATA, M_RDATA} i2c_mode_e;

  i2c_mode_e   mode      = M_ADDR;
  bit          in_frame  = 1'b0;
  bit          ptr_set   = 1'b0;
  bit          rw        = 1'b0;
  bit          m_nack    = 1'b0;
  bit          pulse_seen = 1'b0;  // a posedge occurred for this bit
  int          bit_idx   = 0;
  byte unsigned shreg    = 8'h00;
  byte unsigned ptr      = 8'h00;
  int          xact_wr   = 0;      // observability: writes seen
  int          xact_rd   = 0;      // observability: read bytes served

  // START: SDA falls while SCL high (master only moves SDA at SCL low
  // except for START/STOP, and this slave only moves it at SCL low)
  always @(negedge sda_bus) begin
    if (scl === 1'b1) begin
      in_frame   = 1'b1;
      mode       = M_ADDR;
      bit_idx    = 0;
      shreg      = '0;
      sda_pull   = 1'b0;
      pulse_seen = 1'b0;
    end
  end

  // STOP: SDA rises while SCL high
  always @(posedge sda_bus) begin
    if (scl === 1'b1) begin
      in_frame = 1'b0;
      ptr_set  = 1'b0;
      sda_pull = 1'b0;
    end
  end

  // sample on SCL rising
  always @(posedge scl) begin
    if (in_frame) begin
      pulse_seen = 1'b1;
      if (bit_idx < 8) begin
        if (mode != M_RDATA) shreg = {shreg[6:0], sda_bus === 1'b1};
      end
      else if (mode == M_RDATA) m_nack = (sda_bus === 1'b1);
    end
  end

  // act on SCL falling.  Only a falling edge that ends a real clock
  // pulse counts: the SCL fall that completes a START (or repeated
  // START) has seen no posedge for this bit and must not advance
  // bit_idx -- v1 counted it, assembled the address one bit short and
  // NACKed every transaction (all-0xFF reads on the host side).
  always @(negedge scl) begin
    if (in_frame && pulse_seen) begin
      pulse_seen = 1'b0;
      bit_idx++;
      if (bit_idx == 8) begin
        // 8 data bits done: ack slot follows
        case (mode)
          M_ADDR: begin
            if (shreg[7:1] == I2C_ADDR) begin
              rw       = shreg[0];
              sda_pull = 1'b1;                     // ACK
            end
            else in_frame = 1'b0;                  // not for us
          end
          M_WDATA: begin
            if (!ptr_set) begin ptr = shreg; ptr_set = 1'b1; end
            else begin host_write(ptr, shreg); ptr++; xact_wr++; end
            sda_pull = 1'b1;                       // ACK
          end
          M_RDATA: sda_pull = 1'b0;                // release for m ack
        endcase
      end
      else if (bit_idx >= 9) begin
        // ack slot done: set up the next byte
        bit_idx = 0;
        case (mode)
          M_ADDR: begin
            sda_pull = 1'b0;
            if (rw) begin
              mode  = M_RDATA;
              shreg = regs[ptr];
              xact_rd++;
              sda_pull = !shreg[7];                // drive bit 7
            end
            else begin
              mode  = M_WDATA;
              shreg = '0;
            end
          end
          M_WDATA: begin
            sda_pull = 1'b0;
            shreg    = '0;
          end
          M_RDATA: begin
            if (!m_nack) begin
              ptr++;
              shreg = regs[ptr];
              xact_rd++;
              sda_pull = !shreg[7];
            end
            else sda_pull = 1'b0;                  // master done
          end
        endcase
      end
      else if (mode == M_RDATA && bit_idx < 8) begin
        sda_pull = !shreg[7 - bit_idx];            // next data bit
      end
    end
  end

endmodule : bq76952_rnm
