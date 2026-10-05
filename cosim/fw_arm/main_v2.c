/*======================================================================
 * main_v2.c -- the BMS host mission under the v2 VIRTUAL-TIME
 * QUANTUM-COUPLED bridge (Renode/STM32G0).
 *
 * What changed from v1 (lockstep):
 *   * No ADV register.  The firmware never declares time; its own
 *     execution (every instruction, every spin loop) costs board
 *     time, because Renode's quantum engine advances the board as
 *     CPU virtual time elapses.  Delays are real busy-waits against
 *     the bridge's board-time register (TNOW).
 *   * The AFE's ALERT is a real NVIC interrupt (IRQ 30).  The trip
 *     is discovered by ISR, mid-execution, microseconds after the
 *     board event, instead of at the next 2 ms poll.  The poll loop
 *     still runs for telemetry (same line format as v1, so the same
 *     cross-domain checker grades both).
 *====================================================================*/

#include <stdint.h>

/* ---- v2 bridge (0x60000100) ---- */
#define BR_PINS  (*(volatile uint32_t *)0x60000100u)
#define BR_SDA   (*(volatile uint32_t *)0x60000104u)
#define BR_TLO   (*(volatile uint32_t *)0x60000108u)
#define BR_THI   (*(volatile uint32_t *)0x6000010Cu)
#define BR_FIN   (*(volatile uint32_t *)0x60000110u)

/* ---- NVIC (Cortex-M0+) ---- */
#define NVIC_ISER (*(volatile uint32_t *)0xE000E100u)
#define NVIC_ICER (*(volatile uint32_t *)0xE000E180u)
#define ALERT_IRQ 30

/* ---- USART2, v2 register map (G0) ---- */
#define USART2_CR1 (*(volatile uint32_t *)0x40004400u)
#define USART2_ISR (*(volatile uint32_t *)0x4000441Cu)
#define USART2_TDR (*(volatile uint32_t *)0x40004428u)

/* ---- AFE demo register map ---- */
#define AFE_ADDR 0x08
#define R_SAFETY 0x03
#define R_CELLS  0x14
#define R_CURR   0x3A
#define R_CUV    0x90
#define R_COV    0x92
#define R_OCD    0x94
#define R_PROTEN 0x96
#define R_FETALW 0x97
#define R_CB     0x98
#define R_RECOV  0x99
#define SS_OCD   0x04

volatile int alert_flag = 0;
volatile uint32_t isr_t_us = 0;      /* board time when the ISR ran */
void Alert_IRQHandler(void)
{
    uint32_t hi, lo;
    do { hi = BR_THI; lo = BR_TLO; } while (BR_THI != hi);
    isr_t_us = (uint32_t)((((uint64_t)hi << 32) | lo) / 1000u);
    alert_flag = 1;
    NVIC_ICER = (1u << ALERT_IRQ);   /* level source: mask ourselves */
}

/* =================== UART =================== */
static void putc_(char c)
{
    while (!(USART2_ISR & 0x80)) { }
    USART2_TDR = (uint32_t)c;
}
static void puts_(const char *s) { while (*s) putc_(*s++); }
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

/* =================== board time (read, never written) ============ */
static uint64_t tnow(void)
{
    uint32_t hi, lo;
    do { hi = BR_THI; lo = BR_TLO; } while (BR_THI != hi);
    return ((uint64_t)hi << 32) | lo;
}
static void put_t(void)
{
    uint64_t t = tnow();
    puts_("[fw t=");
    putu((uint32_t)(t / 1000000u));
    putc_('.');
    putu((uint32_t)((t / 100000u) % 10u));
    puts_("ms] ");
}
/* real waiting: spin until the BOARD says the time has passed.  The
 * spinning itself is what makes board time pass (quantum engine). */
static void wait_until(uint64_t t_ns)
{
    while (tnow() < t_ns) { }
}

/* =================== bit-banged I2C =================== */
/* Bit timing is the CPU's own cost: a calibrated spin, not a declared
 * delay.  ~2.5 us per quarter-bit at the default 100 MIPS. */
static void qdel(void)
{
    for (volatile int i = 0; i < 60; i++) { }
}
static void pins(int scl, int sda_rel)
{
    BR_PINS = (uint32_t)((scl & 1) | ((sda_rel ? 0 : 1) << 1));
}
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
static int i2c_tx(uint8_t b)
{
    for (int i = 7; i >= 0; i--) {
        pins(0, (b >> i) & 1); qdel();
        pins(1, (b >> i) & 1); qdel(); qdel();
        pins(0, (b >> i) & 1); qdel();
    }
    pins(0, 1); qdel();
    pins(1, 1); qdel();
    int ack = !(BR_SDA & 1);
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
        v = (uint8_t)((v << 1) | (BR_SDA & 1));
        qdel();
        pins(0, 1); qdel();
    }
    pins(0, ack ? 0 : 1); qdel();
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
    i2c_start();
    if (!i2c_tx((uint8_t)((AFE_ADDR << 1) | 1))) nacks++;
    for (int i = 0; i < n; i++) d[i] = i2c_rx(i < n - 1);
    i2c_stop();
}
static void wr16(uint8_t reg, uint16_t v)
{
    uint8_t d[2] = { (uint8_t)(v & 0xff), (uint8_t)(v >> 8) };
    afe_wr(reg, d, 2);
}
static void wr8(uint8_t reg, uint8_t v) { afe_wr(reg, &v, 1); }

/* =================== the mission =================== */
int main(void)
{
    uint8_t d[4];

    USART2_CR1 = (1u << 0) | (1u << 3);
    puts_("\n[fw] BMS host up on Renode/STM32G0 (v2 quantum-coupled);"
          " board = SV-RNM in xezim\n");

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

    NVIC_ISER = (1u << ALERT_IRQ);     /* arm the ALERT interrupt */
    put_t(); puts_("ALERT IRQ armed; polling for telemetry only\n");

#ifdef FAULT_REG_OFF1
    /* INJECTED BUG: cell readout starts one register too high */
#define R_CELLS_RD (R_CELLS + 1)
#else
#define R_CELLS_RD R_CELLS
#endif

    int tripped = 0, recovered = 0, bus_warned = 0, tele_warned = 0;
    uint64_t next_poll = tnow() + 2000000u;
    for (int loop = 0; loop < 60 && !recovered; loop++) {
        /* wait for the next poll slot, but let the ISR break in */
        while (tnow() < next_poll && !alert_flag) { }
        next_poll = tnow() + 2000000u;

        if (alert_flag && !tripped) {
            tripped = 1;
            uint64_t t_irq = tnow();
            uint8_t ss;
            afe_rd(R_SAFETY, &ss, 1);
            put_t(); puts_("*** ALERT IRQ: isr at t=");
            putu(isr_t_us);
            puts_("us, seen at t=");
            putu((uint32_t)(t_irq / 1000u));
            puts_("us ss=0x"); putu(ss);
            puts_(" -- OCD TRIP seen over I2C -- current stopped by the AFE\n");
            /* wait out the overload in BOARD time, then clear */
            wait_until(42000000u);     /* scenario drops the load at 40 ms */
            wr8(R_RECOV, 0x01);
            put_t(); puts_("recover written (0x99=1)\n");
            continue;
        }

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

        if (tripped && !(ss & SS_OCD) && ma > 400) {
            recovered = 1;
            put_t(); puts_("*** RECOVERED: latch cleared, current flowing again (");
            puti(ma); puts_("mA)\n");
        }
    }

    if (!recovered) { put_t(); puts_("!!! mission incomplete\n"); }
    puts_("[fw] done; stopping the board sim\n");
    BR_FIN = 1;
    for (;;) { }
}
