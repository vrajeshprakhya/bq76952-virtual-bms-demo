/*======================================================================
 * main_i2cdrv.c -- the I2C DRIVER RUNG: the same BMS mission, but the
 * firmware never touches a pin.  It drives the STM32 G0's real I2C1
 * controller (v2 peripheral: CR1/CR2/ISR/TXDR/RXDR), exactly as the
 * production code on the schematic's U2 would: program the slave
 * address and byte count into CR2, fire START, feed TXDR on TXIS,
 * drain RXDR on RXNE, handle TC and STOPF.  Renode models the
 * controller; a harness-side slave executes every byte transaction as
 * real edges on the pin-level board, so the bus is still wires
 * underneath -- the bit-banging moved from the firmware (where it was
 * a stand-in) to the harness (where a bus-functional model belongs).
 *
 * Time: the harness's quantum engine meters CPU execution to the
 * board (bench-like); board time is read from TNOW at 0x60000208.
 * Mission and log format match the BMS missions, so the same
 * cross-domain checker grades this rung.
 *====================================================================*/

#include <stdint.h>

/* ---- harness registers (XezimPinMaster) ---- */
#define H_TLO (*(volatile uint32_t *)0x60000208u)
#define H_THI (*(volatile uint32_t *)0x6000020Cu)
#define H_FIN (*(volatile uint32_t *)0x60000210u)

/* ---- USART2, v2 map (G0) ---- */
#define USART2_CR1 (*(volatile uint32_t *)0x40004400u)
#define USART2_ISR (*(volatile uint32_t *)0x4000441Cu)
#define USART2_TDR (*(volatile uint32_t *)0x40004428u)

/* ---- I2C1, v2 controller (G0, RM0444) ---- */
#define I2C_CR1    (*(volatile uint32_t *)0x40005400u)
#define I2C_CR2    (*(volatile uint32_t *)0x40005404u)
#define I2C_TIMING (*(volatile uint32_t *)0x40005410u)
#define I2C_ISR    (*(volatile uint32_t *)0x40005418u)
#define I2C_ICR    (*(volatile uint32_t *)0x4000541Cu)
#define I2C_RXDR   (*(volatile uint32_t *)0x40005424u)
#define I2C_TXDR   (*(volatile uint32_t *)0x40005428u)
#define CR1_PE     (1u << 0)
#define CR2_RD     (1u << 10)
#define CR2_START  (1u << 13)
#define CR2_STOP   (1u << 14)
#define CR2_AUTOEND (1u << 25)
#define ISR_TXIS   (1u << 1)
#define ISR_RXNE   (1u << 2)
#define ISR_NACKF  (1u << 4)
#define ISR_STOPF  (1u << 5)
#define ISR_TC     (1u << 6)

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

/* =================== console =================== */
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

/* =================== board time (harness-metered) ============== */
static uint64_t tnow(void)
{
    uint32_t hi, lo;
    do { hi = H_THI; lo = H_TLO; } while (H_THI != hi);
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
static void wait_until(uint64_t t_ns)
{
    while (tnow() < t_ns) { }
}

/* =================== the real I2C driver =================== */
static int nacks = 0;

static int i2c_wait(uint32_t flag)
{
    for (;;) {
        uint32_t s = I2C_ISR;
        if (s & ISR_NACKF) { nacks++; I2C_ICR = ISR_NACKF; return 0; }
        if (s & flag) return 1;
    }
}
static void i2c_write(uint8_t reg, const uint8_t *d, int n)
{
    I2C_CR2 = ((uint32_t)AFE_ADDR << 1)
            | ((uint32_t)(n + 1) << 16)
            | CR2_START | CR2_AUTOEND;
    if (!i2c_wait(ISR_TXIS)) return;
    I2C_TXDR = reg;
    for (int i = 0; i < n; i++) {
        if (!i2c_wait(ISR_TXIS)) return;
        I2C_TXDR = d[i];
    }
    i2c_wait(ISR_STOPF);
    I2C_ICR = ISR_STOPF;
}
static void i2c_read(uint8_t reg, uint8_t *d, int n)
{
    /* write phase: register index, no autoend */
    I2C_CR2 = ((uint32_t)AFE_ADDR << 1)
            | (1u << 16)
            | CR2_START;
    if (!i2c_wait(ISR_TXIS)) return;
    I2C_TXDR = reg;
    if (!i2c_wait(ISR_TC)) return;
    /* read phase: repeated start */
    I2C_CR2 = ((uint32_t)AFE_ADDR << 1)
            | ((uint32_t)n << 16)
            | CR2_RD | CR2_START | CR2_AUTOEND;
    for (int i = 0; i < n; i++) {
        if (!i2c_wait(ISR_RXNE)) return;
        d[i] = (uint8_t)I2C_RXDR;
    }
    i2c_wait(ISR_STOPF);
    I2C_ICR = ISR_STOPF;
}
static void wr16(uint8_t reg, uint16_t v)
{
    uint8_t d[2] = { (uint8_t)(v & 0xff), (uint8_t)(v >> 8) };
    i2c_write(reg, d, 2);
}
static void wr8(uint8_t reg, uint8_t v) { i2c_write(reg, &v, 1); }

/* =================== the mission =================== */
int main(void)
{
    uint8_t d[4];

    USART2_CR1 = (1u << 0) | (1u << 3);
    I2C_TIMING = 0x00303D5B;       /* nominal 100 kHz (model ignores) */
    I2C_CR1    = CR1_PE;

    puts_("\n[fw] BMS host up on Renode/STM32G0 (REAL I2C1 driver);"
          " board = SV-RNM in xezim\n");

    wr16(R_CUV, 2800);
    wr16(R_COV, 4250);
    wr16(R_OCD, 3000);
    wr8(R_PROTEN, 0x0F);
    wr8(R_FETALW, 0x03);
    wr8(R_CB, 0x00);
    put_t(); puts_("AFE protection configured (CUV 2800mV COV 4250mV OCD 3000mA)\n");

    int tripped = 0, recovered = 0, bus_warned = 0;
    uint64_t next_poll = tnow() + 2000000u;
    for (int loop = 0; loop < 60 && !recovered; loop++) {
        wait_until(next_poll);
        next_poll = tnow() + 2000000u;

        uint8_t ss;
        i2c_read(R_SAFETY, &ss, 1);
        i2c_read(R_CELLS, d, 2);
        int c1 = d[0] | (d[1] << 8);
        i2c_read(R_CURR, d, 2);
        int ma = (int16_t)(d[0] | (d[1] << 8));

        put_t();
        puts_("ss=0x"); putu(ss);
        puts_(" c1="); puti(c1);
        puts_("mV i="); puti(ma);
        puts_("mA\n");

        if (nacks && !bus_warned) {
            bus_warned = 1;
            put_t(); puts_("*** I2C FAULT: slave not ACKing (");
            puti(nacks); puts_(" NACKs)\n");
        }

        if (!tripped && (ss & SS_OCD)) {
            tripped = 1;
            put_t(); puts_("*** OCD TRIP seen over I2C -- current stopped by the AFE\n");
            wait_until(42000000u);
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
    H_FIN = 1;
    for (;;) { }
}
