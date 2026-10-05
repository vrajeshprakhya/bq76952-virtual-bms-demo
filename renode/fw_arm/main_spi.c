/*======================================================================
 * main_spi.c -- the SECOND PROTOCOL on the framework: an HX717-class
 * load-cell ADC (SPI-family two-wire: SCLK out, DOUT in) read in
 * bench-like time on unmodified mainline QEMU + icount.
 *
 * Same metering core as the BMS mission (SysTick is the virtual-time
 * ruler; time beacons every ~10 us of measured execution; harness
 * time excluded from the ledger), same bridge verbs; only the pin map
 * and the protocol recipe differ:
 *   out bit 0 = SCLK;  in bit 0 = DOUT (low = conversion ready;
 *   24 data bits MSB-first, each valid after an SCLK rising edge;
 *   the 25th pulse returns DOUT high and programs gain 128).
 *
 * Mission: tare the empty scale, stream conversions at 320 SPS, and
 * detect the 2000 g weight the scenario drops at 151 ms; the
 * expected delta is 1,717,987 counts (4 mV in a 19.531 mV full
 * scale), which the cross-domain checker verifies against the
 * board's own event log.
 *====================================================================*/

#include <stdint.h>

/* ---- USART1 = bridge, USART2 = console (v1 map, F405) ---- */
#define U1_SR  (*(volatile uint32_t *)0x40011000u)
#define U1_DR  (*(volatile uint32_t *)0x40011004u)
#define U1_CR1 (*(volatile uint32_t *)0x4001100Cu)
#define U2_SR  (*(volatile uint32_t *)0x40004400u)
#define U2_DR  (*(volatile uint32_t *)0x40004404u)
#define U2_CR1 (*(volatile uint32_t *)0x4000440Cu)
#define CR1_EN ((1u << 13) | (1u << 3) | (1u << 2))

/* ---- SysTick: the virtual-time ruler ---- */
#define STK_CSR (*(volatile uint32_t *)0xE000E010u)
#define STK_RVR (*(volatile uint32_t *)0xE000E014u)
#define STK_CVR (*(volatile uint32_t *)0xE000E018u)
#define TICKS_PER_US 168u
#define QUANTUM_US   10u

/* =================== console =================== */
static uint32_t last_cvr;
static void putc_(char c)
{
    while (!(U2_SR & 0x80)) { }
    U2_DR = (uint32_t)c;
    last_cvr = STK_CVR;        /* console readiness is harness time */
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

/* =================== bridge link =================== */
static void u1_putc(char c)
{
    while (!(U1_SR & 0x80)) { }
    U1_DR = (uint32_t)c;
}
static char u1_getc(void)
{
    while (!(U1_SR & 0x20)) { }
    return (char)(U1_DR & 0xff);
}
static void u1_dec(uint32_t v)
{
    char b[12]; int i = 0;
    if (!v) { u1_putc('0'); return; }
    while (v) { b[i++] = (char)('0' + v % 10); v /= 10; }
    while (i) u1_putc(b[--i]);
}

static uint32_t in_pins = 1;       /* bit 0 = DOUT */

static void read_ack(void)         /* "K <in_hex> <alert>\n" */
{
    char c; int field = 0; uint32_t v = 0;
    while ((c = u1_getc()) != '\n') {
        if (c == ' ') field++;
        else if (field == 1) {
            uint32_t d = (c >= 'a') ? (uint32_t)(c - 'a' + 10)
                       : (c >= 'A') ? (uint32_t)(c - 'A' + 10)
                       : (uint32_t)(c - '0');
            v = (v << 4) | d;
        }
        /* alert field unused on this board */
    }
    in_pins = v;
    last_cvr = STK_CVR;            /* ack waits are harness time */
}

/* =================== bench-like time metering =================== */
static uint32_t tick_rem;
static uint64_t t_board_ns;

static void time_init(void)
{
    STK_RVR = 0x00FFFFFFu;
    STK_CVR = 0;
    STK_CSR = 0x5;
    last_cvr = STK_CVR;
}
static uint32_t ticks_elapsed(void)
{
    uint32_t now = STK_CVR;
    uint32_t d = (last_cvr - now) & 0x00FFFFFFu;
    last_cvr = now;
    return d;
}
static void sync_time(void)
{
    tick_rem += ticks_elapsed();
    uint32_t us = tick_rem / TICKS_PER_US;
    if (us == 0) return;
    tick_rem -= us * TICKS_PER_US;
    u1_putc('A'); u1_putc(' ');
    u1_dec(us * 1000u); u1_putc('\n');
    read_ack();
    t_board_ns += (uint64_t)us * 1000u;
}
static void put_t(void)
{
    puts_("[fw t=");
    putu((uint32_t)(t_board_ns / 1000000u));
    putc_('.');
    putu((uint32_t)((t_board_ns / 100000u) % 10u));
    puts_("ms] ");
}

/* =================== pin HAL (generic bridge) =================== */
static void set_out(uint32_t mask)
{
    sync_time();                   /* flush: edge lands at its instant */
    u1_putc('S'); u1_putc(' ');
    /* tiny hex printer */
    {
        char b[9]; int i = 0;
        if (!mask) { u1_putc('0'); }
        else {
            while (mask) { b[i++] = "0123456789abcdef"[mask & 0xf];
                           mask >>= 4; }
            while (i) u1_putc(b[--i]);
        }
    }
    u1_putc('\n');
    read_ack();
}
/* ~1 us of real execution between edges (HX71x min high is 0.2 us) */
static void edel(void)
{
    uint32_t t0 = STK_CVR;
    while (((t0 - STK_CVR) & 0x00FFFFFFu) < TICKS_PER_US) { }
}

/* =================== HX717 protocol =================== */
#define SCLK 1u

static void wait_ready(void)       /* DOUT low = conversion ready */
{
    while (in_pins & 1u) {
        uint32_t t0 = STK_CVR;
        while (((t0 - STK_CVR) & 0x00FFFFFFu)
               < QUANTUM_US * TICKS_PER_US) { }
        sync_time();               /* beacon; its ack refreshes DOUT */
    }
}
static int32_t hx_read(void)       /* 24 bits + 25th pulse, gain 128 */
{
    uint32_t w = 0;
    for (int i = 0; i < 24; i++) {
        set_out(SCLK); edel();     /* bit valid after the rising edge */
        w = (w << 1) | (in_pins & 1u);
        set_out(0);    edel();
    }
    set_out(SCLK); edel();         /* 25th pulse: DOUT high, gain 128 */
    set_out(0);    edel();
    if (w & 0x800000u) w |= 0xFF000000u;   /* sign extend */
    return (int32_t)w;
}

static void qemu_exit(void)
{
    register uint32_t r0 asm("r0") = 0x18;
    register uint32_t r1 asm("r1") = 0x20026;
    asm volatile("bkpt 0xAB" :: "r"(r0), "r"(r1) : "memory");
}

/* =================== the mission =================== */
int main(void)
{
    U1_CR1 = CR1_EN;
    U2_CR1 = CR1_EN;
    time_init();

    puts_("\n[fw] load-cell mission (HX717, SPI-family) on QEMU+icount;"
          " board = SV-RNM in xezim\n");

    int32_t tare = 0;
    int detected = 0, done = 0;
    for (int n = 0; n < 120 && !done; n++) {
        wait_ready();
        int32_t c = hx_read();

        if (n < 4) {
            tare += c / 4;         /* average the first four as tare */
            put_t(); puts_("n="); putu((uint32_t)n);
            puts_(" counts="); puti(c); puts_(" (taring)\n");
            continue;
        }

        int32_t delta = c - tare;
        put_t(); puts_("n="); putu((uint32_t)n);
        puts_(" counts="); puti(c);
        puts_(" delta="); puti(delta); puts_("\n");

        if (!detected && delta > 800000) {
            detected = 1;
            put_t(); puts_("*** WEIGHT detected: delta=");
            puti(delta); puts_(" counts\n");
        }
        else if (detected) {
            static int after = 0;
            if (++after >= 4) {
                put_t(); puts_("*** steady at delta=");
                puti(delta); puts_(" counts -- mission complete\n");
                done = 1;
            }
        }
    }

    if (!done) { put_t(); puts_("!!! mission incomplete\n"); }
    puts_("[fw] done; stopping the board sim\n");
    sync_time();
    u1_putc('F'); u1_putc('\n');
    read_ack();
    qemu_exit();
    for (;;) { }
}
