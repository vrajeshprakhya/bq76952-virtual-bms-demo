/*======================================================================
 * main.c -- REAL bare-metal BMS host firmware (the mission), talking
 * to the SV-RNM board simulated in xezim.  Platform-agnostic: the
 * five operations it needs come from hal.h, implemented once for
 * Renode (STM32G0, custom MMIO bridge peripheral) and once for
 * mainline QEMU (STM32F405, bridge over a spare UART).  Board time
 * advances only through hal_adv, so the board timeline is identical
 * under either emulator.
 *
 * This is the natural-C version of the host logic the UVM regression
 * exercises (same demo AFE register map): blocking bit-banged I2C,
 * straight-line control flow, UART prints.  No tick-FSM contortions
 * -- an emulator makes blocking code just work.
 *
 * Mission: configure the AFE's protection over I2C, poll the pack,
 * and ride out an overload: the AFE (in the RNM!) trips OCD when the
 * testbench raises the load to 4.2 A; we report it, wait for the
 * load to clear, write the recover register, and confirm.
 *
 * FAULT INJECTION (for the catch-the-bug demo; see ../run_faults.sh):
 *   -DFAULT_OCD_SWAP  the OCD threshold write has its bytes swapped
 *                     (3000 mA becomes 47115 mA -- protection armed
 *                     with a dead trigger)
 *   -DFAULT_REG_OFF1  cell readout starts one register too high
 *                     (classic off-by-one: c1 becomes MSB(c1)|LSB(c2))
 * Board- and bridge-side faults are injected in SV / the DPI server.
 *====================================================================*/

#include <stdint.h>
#include "hal.h"

/* ---- AFE demo register map (matches design/rnm/bq76952_rnm.sv) ---- */
#define AFE_ADDR 0x08
#define R_SAFETY 0x03
#define R_CELLS  0x14
#define R_CURR   0x3A
#define R_FETS   0x7F
#define R_CUV    0x90
#define R_COV    0x92
#define R_OCD    0x94
#define R_PROTEN 0x96
#define R_FETALW 0x97
#define R_CB     0x98
#define R_RECOV  0x99
#define SS_OCD   0x04

/* =================== UART =================== */
static void putc_(char c)
{
    hal_putc(c);
}
static void puts_(const char *s)
{
    while (*s) putc_(*s++);
}
static void putu(uint32_t v)
{
    char b[12]; int i = 0;
    if (!v) { putc_('0'); return; }
    while (v) { b[i++] = (char)('0' + v % 10); v /= 10; }
    while (i) putc_(b[--i]);
}
static void puti(int32_t v)
{
    if (v < 0) { putc_('-'); v = -v; }
    putu((uint32_t)v);
}

/* =================== board time =================== */
static uint64_t t_ns = 0;
static void adv(uint32_t ns)
{
    hal_adv(ns);
    t_ns += ns;
}
static void put_t(void)
{
    puts_("[fw t=");
    putu((uint32_t)(t_ns / 1000000u));
    putc_('.');
    putu((uint32_t)((t_ns / 100000u) % 10u));
    puts_("ms] ");
}

/* =================== bit-banged I2C =================== */
#define QNS 2500u                 /* quarter bit: 100 kHz */
static void pins(int scl, int sda_rel)
{
    hal_set_pins(scl & 1, sda_rel ? 0 : 1);
}
static void qdel(void) { adv(QNS); }

static void i2c_start(void)
{
    pins(1, 1); qdel();
    pins(1, 0); qdel();
    pins(0, 0); qdel();
}
static void i2c_stop(void)
{
    pins(0, 0); qdel();
    pins(1, 0); qdel();
    pins(1, 1); qdel();
}
static int i2c_tx(uint8_t b)          /* returns ACK (1 = acked) */
{
    for (int i = 7; i >= 0; i--) {
        pins(0, (b >> i) & 1); qdel();
        pins(1, (b >> i) & 1); qdel(); qdel();
        pins(0, (b >> i) & 1); qdel();
    }
    pins(0, 1); qdel();               /* release for slave ACK */
    pins(1, 1); qdel();
    int ack = !(hal_sda() & 1);
    qdel();
    pins(0, 1); qdel();
    return ack;
}
static uint8_t i2c_rx(int ack)
{
    uint8_t v = 0;
    for (int i = 7; i >= 0; i--) {
        pins(0, 1); qdel();
        pins(1, 1); qdel();
        v = (uint8_t)((v << 1) | (hal_sda() & 1));
        qdel();
        pins(0, 1); qdel();
    }
    pins(0, ack ? 0 : 1); qdel();     /* master ACK/NACK */
    pins(1, ack ? 0 : 1); qdel(); qdel();
    pins(0, 1); qdel();
    return v;
}

static int nacks = 0;                 /* bus-health telemetry */

static void afe_wr(uint8_t reg, const uint8_t *d, int n)
{
    i2c_start();
    if (!i2c_tx((uint8_t)(AFE_ADDR << 1))) nacks++;
    i2c_tx(reg);
    for (int i = 0; i < n; i++) i2c_tx(d[i]);
    i2c_stop();
}
static void afe_rd(uint8_t reg, uint8_t *d, int n)
{
    i2c_start();
    if (!i2c_tx((uint8_t)(AFE_ADDR << 1))) nacks++;
    i2c_tx(reg);
    i2c_start();                       /* repeated start */
    if (!i2c_tx((uint8_t)((AFE_ADDR << 1) | 1))) nacks++;
    for (int i = 0; i < n; i++) d[i] = i2c_rx(i < n - 1);
    i2c_stop();
}
static void wr16(uint8_t reg, uint16_t v)
{
    uint8_t d[2] = { (uint8_t)(v & 0xff), (uint8_t)(v >> 8) };
    afe_wr(reg, d, 2);
}
static void wr8(uint8_t reg, uint8_t v)
{
    afe_wr(reg, &v, 1);
}

/* =================== the mission =================== */
int main(void)
{
    uint8_t d[12];

    hal_init();
    puts_("\n[fw] BMS host up on ");
    puts_(hal_name);
    puts_("; board = SV-RNM in xezim\n");

    /* configure the AFE's protection engine over the bus */
    wr16(R_CUV, 2800);
    wr16(R_COV, 4250);
#ifdef FAULT_OCD_SWAP
    /* INJECTED BUG: byte-swapped threshold write -> 0xB80B = 47115 mA */
    {
        uint8_t sw[2] = { (uint8_t)(3000 >> 8), (uint8_t)(3000 & 0xff) };
        afe_wr(R_OCD, sw, 2);
    }
#else
    wr16(R_OCD, 3000);
#endif
    wr8(R_PROTEN, 0x0F);
    wr8(R_FETALW, 0x03);
    wr8(R_CB, 0x00);
    put_t(); puts_("AFE protection configured (CUV 2800mV COV 4250mV OCD 3000mA)\n");

#ifdef FAULT_REG_OFF1
    /* INJECTED BUG: cell readout starts one register too high */
#define R_CELLS_RD (R_CELLS + 1)
#else
#define R_CELLS_RD R_CELLS
#endif

    int tripped = 0, recovered = 0, bus_warned = 0, tele_warned = 0;
    for (int loop = 0; loop < 45 && !recovered; loop++) {
        adv(2000000u);                 /* 2 ms between polls */

        uint8_t ss;
        afe_rd(R_SAFETY, &ss, 1);
        afe_rd(R_CELLS_RD, d, 2);
        int c1 = d[0] | (d[1] << 8);
        afe_rd(R_CURR, d, 2);
        int ma = (int16_t)(d[0] | (d[1] << 8));

        put_t();
        puts_("ss=0x"); putu(ss);
        puts_(" c1="); puti(c1);
        puts_("mV i="); puti(ma);
        puts_("mA\n");

        /* defence in depth: the firmware's own sanity checks */
        if (nacks && !bus_warned) {
            bus_warned = 1;
            put_t(); puts_("*** I2C FAULT: slave not ACKing (");
            puti(nacks); puts_(" NACKs)\n");
        }
        if ((c1 < 2000 || c1 > 4500) && !tele_warned) {
            tele_warned = 1;
            put_t(); puts_("*** TELEMETRY FAULT: implausible c1=");
            puti(c1); puts_("mV\n");
        }

        if (!tripped && (ss & SS_OCD)) {
            tripped = 1;
            put_t(); puts_("*** OCD TRIP seen over I2C -- current stopped by the AFE\n");
            /* give the operator time to remove the load, then clear */
            adv(30000000u);            /* 30 ms */
            wr8(R_RECOV, 0x01);
            put_t(); puts_("recover written (0x99=1)\n");
        }
        else if (tripped && !(ss & SS_OCD) && ma > 400) {
            recovered = 1;
            put_t(); puts_("*** RECOVERED: latch cleared, current flowing again (");
            puti(ma); puts_("mA)\n");
        }
    }

    if (!recovered) { put_t(); puts_("!!! mission incomplete\n"); }
    puts_("[fw] done; stopping the board sim\n");
    hal_fin();
    for (;;) { }
}
