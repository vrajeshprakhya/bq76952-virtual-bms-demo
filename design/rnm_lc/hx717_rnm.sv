`timescale 1ns/1ps
//======================================================================
// hx717_rnm -- behavioural model of the HX717-class 24-bit sigma-delta
// bridge ADC (HX711 family protocol).
//
// Captured behaviours -- the ones that can change what firmware sees:
//   * ratiometric conversion: full scale = +/-0.5*AVDD/GAIN, so a
//     bridge excited from AVDD cancels the excitation corner
//   * PGA gain, 24-bit quantisation, rail clamp
//   * a fixed INPUT-REFERRED offset (HXOFF) that is NOT ratiometric --
//     the one term that makes the excitation corner visible at all
//   * input-referred noise per conversion
//   * conversion rate (320 SPS default)
//   * THE PROTOCOL RULE: after the 24 data bits, the total number of
//     SCLK pulses programs the NEXT conversion --
//        25 -> channel A gain 128, 26 -> B gain 32, 27 -> A gain 64.
//     A firmware that clocks 27 pulses gets no error; its data just
//     silently halves from the next-but-one conversion on.
//   * SCLK high > 60 us powers the part down (por_cnt counts resets).
//
// DOUT falls when data is ready; data bits shift out MSB-first on the
// SCLK rising edges; DOUT returns high on the 25th rising edge.
//======================================================================
module hx717_rnm #(
  parameter real TCONV_NS = 3125000.0,  // 320 SPS
  parameter real HXOFF_V  = 10.0e-6,    // input-referred, fixed
  parameter real NOISE_V  = 1.0e-6,     // +/- per conversion
  parameter real PD_US    = 60.0        // SCLK-high power-down limit
)(
  input  wreal avdd,        // = bridge excitation (ratiometric)
  input  wreal vin,         // channel A differential input
  input  logic sclk,
  output logic dout
);

  int         code      = 0;
  logic [23:0] word     = '0;
  int         pulse_cnt = 0;
  int         gain      = 128;   // conversion in progress
  int         next_gain = 128;   // programmed by pulse count
  bit         chan_b    = 1'b0;
  bit         data_rdy  = 1'b0;
  int         por_cnt   = 0;     // power-down resets seen
  bit         pdown     = 1'b0;
  real        sclk_rise_t = -1.0;

  initial dout = 1'b1;

  //--- continuous conversions -----------------------------------------
  always begin
    #(TCONV_NS);
    if (!pdown) begin
      real v, noise, fs;
      int  c;
      gain  = next_gain;
      noise = (real'($urandom_range(0, 2000)) - 1000.0) / 1000.0 * NOISE_V;
      v     = (chan_b ? 0.0 : vin) + HXOFF_V + noise;
      fs    = 0.5 * avdd / real'(gain);          // +/- full scale input
      c     = $rtoi(v / fs * 8388608.0 + (v >= 0.0 ? 0.5 : -0.5));
      if (c >  8388607) c =  8388607;
      if (c < -8388608) c = -8388608;
      code      = c;
      word      = 24'(c);
      pulse_cnt = 0;
      data_rdy  = 1'b1;
      dout      = 1'b0;                          // data ready
    end
  end

  //--- readout + gain programming -------------------------------------
  always @(posedge sclk) begin
    sclk_rise_t = $realtime;
    if (data_rdy) begin
      pulse_cnt++;
      if (pulse_cnt <= 24) begin
        dout = word[23];                         // MSB first
        word = {word[22:0], 1'b0};
      end
      case (pulse_cnt)
        25: begin dout = 1'b1; next_gain = 128; chan_b = 1'b0; end
        26: begin next_gain = 32;  chan_b = 1'b1; end
        27: begin next_gain = 64;  chan_b = 1'b0; end
        default: ;
      endcase
      if (pulse_cnt >= 27) data_rdy = 1'b0;    // train fully consumed
    end
  end

  // NOTE: no close-out on the 25th falling edge -- the part acts on
  // every pulse as it arrives, which is exactly what lets a 27-pulse
  // firmware silently reprogram the gain.  (A v1 of this model closed
  // the readout at pulse 25 and the gain-bug scenario caught it: the
  // PGA stayed at 128.)  pulse_cnt and data_rdy reset at the next
  // conversion boundary instead.
  always @(negedge sclk) begin
    if (pdown) pdown = 1'b0;                    // wake on SCLK low
    sclk_rise_t = -1.0;
  end

  //--- SCLK-high power-down watchdog ----------------------------------
  always #(10000) begin
    if (sclk === 1'b1 && sclk_rise_t >= 0.0
        && ($realtime - sclk_rise_t) > PD_US * 1000.0 && !pdown) begin
      pdown    = 1'b1;
      data_rdy = 1'b0;
      dout     = 1'b1;
      por_cnt++;
      $display("[HX717] t=%0.0fns POWER-DOWN: SCLK held high > %0.0f us",
               $realtime, PD_US);
    end
  end

endmodule : hx717_rnm
