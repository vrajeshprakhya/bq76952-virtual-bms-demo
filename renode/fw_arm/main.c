/*======================================================================
 * main.c -- REAL bare-metal BMS host firmware for the Renode-emulated
 * STM32G0 (the schematic's U2 family), talking to the SV-RNM board
 * simulated in xezim.
 *
 * This is the natural-C version of the host logic the UVM regression
 * exercises (same demo AFE register map): blocking bit-banged I2C,
 * straight-line control flow, UART prints.  No tick-FSM contortions
 * -- the emulator makes blocking code just work.
 *
 * The board is reached through the XezimBridge peripheral at
 * 0x50000000: writes to PINS set SCL/SDA, writes to ADV advance the
 * BOARD's clock by that many ns (the sole source of board time --
 * strict lockstep), reads of SDA return the bus as last sampled.
 *
 * Mission: configure the AFE's protection over I2C, poll the pack,
 * and ride out an overload: the AFE (in the RNM!) trips OCD when the
 * testbench raises the load to 4.2 A; we report it, wait for the
 * load to clear, write the recover register, and confirm.
 *====================================================================*/

#include <stdint.h>

/* ---- the bridge to the xezim board ----
 * 0x6000_0000: free on the STM32G0 (0x5000_0000 is GPIOA there). */
#define BR_PINS  (*(volatile uint32_t *)0x60000000u)  /* b0 SCL, b1 SDA pull */
#define BR_ADV   (*(volatile uint32_t *)0x60000004u)  /* advance board <ns>  */
#define BR_SDA   (*(volatile uint32_t *)0x60000008u)  /* sampled SDA         */
#define BR_FIN   (*(volatile uint32_t *)0x6000000Cu)  /* end the board sim   */

/* ---- USART2, v2 register map (G0/F7 generation) ----
 * CR1 @ 0x00, ISR @ 0x1C (TXE = bit 7), TDR @ 0x28.  NOT the F4's
 * v1 layout (SR @ 0x00, DR @ 0x04) -- polling the wrong offset spins
 * forever.  Renode models it; no clock setup needed. */
#define USART2_CR1 (*(volatile uint32_t *)0x40004400u)
#define USART2_ISR (*(volatile uint32_t *)0x4000441Cu)
#define USART2_TDR (*(volatile uint32_t *)0x40004428u)

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
    while (!(USART2_ISR & 0x80)) { }    /* TXE */
    USART2_TDR = (uint32_t)c;
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
    BR_ADV = ns;
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
static int cur_scl = 1, cur_sda = 1;   /* sda: 1 = released */
static void pins(int scl, int sda_rel)
{
    cur_scl = scl; cur_sda = sda_rel;
    BR_PINS = (uint32_t)((scl & 1) | ((sda_rel ? 0 : 1) << 1));
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
    pins(0, ack ? 0 : 1); qdel();     /* master ACK/NACK */
    pins(1, ack ? 0 : 1); qdel(); qdel();
    pins(0, 1); qdel();
    return v;
}

static void afe_wr(uint8_t reg, const uint8_t *d, int n)
{
    i2c_start();
    i2c_tx((uint8_t)(AFE_ADDR << 1));
    i2c_tx(reg);
    for (int i = 0; i < n; i++) i2c_tx(d[i]);
    i2c_stop();
}
static void afe_rd(uint8_t reg, uint8_t *d, int n)
{
    i2c_start();
    i2c_tx((uint8_t)(AFE_ADDR << 1));
    i2c_tx(reg);
    i2c_start();                       /* repeated start */
    i2c_tx((uint8_t)((AFE_ADDR << 1) | 1));
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

    USART2_CR1 = (1u << 0) | (1u << 3);    /* UE | TE (v2 positions) */
    puts_("\n[fw] BMS host up on Renode/STM32G0; board = SV-RNM in xezim\n");

    /* configure the AFE's protection engine over the bus */
    wr16(R_CUV, 2800);
    wr16(R_COV, 4250);
    wr16(R_OCD, 3000);
    wr8(R_PROTEN, 0x0F);
    wr8(R_FETALW, 0x03);
    wr8(R_CB, 0x00);
    put_t(); puts_("AFE protection configured (CUV 2800mV COV 4250mV OCD 3000mA)\n");

    int tripped = 0, recovered = 0;
    for (int loop = 0; loop < 60 && !recovered; loop++) {
        adv(2000000u);                 /* 2 ms between polls */

        uint8_t ss;
        afe_rd(R_SAFETY, &ss, 1);
        afe_rd(R_CELLS, d, 2);
        int c1 = d[0] | (d[1] << 8);
        afe_rd(R_CURR, d, 2);
        int ma = (int16_t)(d[0] | (d[1] << 8));

        put_t();
        puts_("ss=0x"); putu(ss);
        puts_(" c1="); puti(c1);
        puts_("mV i="); puti(ma);
        puts_("mA\n");

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
    BR_FIN = 1;
    for (;;) { }
}
