* bms_core.inc -- the Figure-2 circuit of the whitepaper as a SPICE
* netlist: 6S li-ion stack with per-cell internal resistance, DSG FET
* (switch model), commanded load gated by the DSG control (exactly the
* RNM law  i_act = DSG * I_load), 1 mOhm shunt, and the NTC divider on
* the TS pin.  Parameters mirror design/rnm/*.sv and the smoke test.
*
* Node map:
*   0            B-  (pack negative, reference)
*   t1..t6       cell taps (t6 = B+); AFE cell k input = v(tk)-v(tk-1)
*   nload, nsh   load branch; v(nsh) is the shunt sense voltage (SRP,
*                with SRN = 0)
*   ctl          DSG gate control (1 = closed)
*   cmd          commanded load current, 1 V per amp
*   tsn          NTC divider mid-point (TS pin)

.param VCELL=3.7
.param RINT=12m
.param RSH=1m
.param TNTC=25
.param RNTCVAL={10k*exp(3435*(1/(TNTC+273.15)-1/298.15))}

* ---- cell stack (bottom to top), each cell EMF behind its Rint ----
V1 m1 0  {VCELL}
R1 t1 m1 {RINT}
V2 m2 t1 {VCELL}
R2 t2 m2 {RINT}
V3 m3 t2 {VCELL}
R3 t3 m3 {RINT}
V4 m4 t3 {VCELL}
R4 t4 m4 {RINT}
V5 m5 t4 {VCELL}
R5 t5 m5 {RINT}
V6 m6 t5 {VCELL}
R6 t6 m6 {RINT}

* ---- discharge FET + gated load + shunt ----
S1    t6 nload ctl 0 dsgsw
.model dsgsw sw vt=0.5 vh=0.1 ron=1m roff=1e9
Bload nload nsh I = V(cmd)*V(ctl)
Rsh   nsh 0 {RSH}

* ---- NTC divider on the TS pin (10k pull-up to the 3.3 V rail) ----
Vdd3  vdd 0 3.3
Rpull vdd tsn 10k
Rntc  tsn 0 {RNTCVAL}
