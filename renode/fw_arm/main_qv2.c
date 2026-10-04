/*======================================================================
 * main_qv2.c -- the BMS mission in BENCH-LIKE time on UNMODIFIED
 * mainline QEMU.
 *
 * Time flows with execution, as on a real bench: QEMU runs with
 * icount (one instruction = a fixed slice of virtual time,
 * deterministic), the free-running SysTick measures that virtual
 * time from inside, and the firmware meters the board accordingly:
 *   - a time beacon ("A <ns>") every ~10 us of its own measured
 *     execution, sent cooperatively from its wait loops (the way an
 *     RTOS tick meters a real system),
 *   - a flush of the un-beaconed tail before every pin access, so
 *     I2C edges land at the right instant,
 *   - the board's ALERT level rides every ack ("K <sda> <alert>");
 *     a rising ALERT is dispatched at the next beacon, within ~10 us
 *     of the board event.
 * Computation is never free here: a slow loop stretches exactly what
 * happens on the wires.
 *
 * Transport: the same UART-chardev line protocol as the plain QEMU
 * build (USART1 -> TCP), against the bridge2 server (port 43602) and
 * the same SV-RNM board in xezim.  Nothing in QEMU is modified.
 *
 * FAULT INJECTION: -DFAULT_OCD_SWAP, -DFAULT_REG_OFF1 as elsewhere.
 *====================================================================*/

#include <stdint.h>

/* ---- USART1 = bridge, USART2 = console (v1 register map, F405) --- */
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
/* STM32F405 SYSCLK is 168 MHz: 168 ticks per us.  QEMU's SysTick
 * counts VIRTUAL time, so under icount this measures the firmware's
 * own deterministic execution cost. */
#define TICKS_PER_US 168u
#define QUANTUM_US   10u

static uint32_t last_cvr;          /* virtual-time ruler position   */

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
    while (!(U2_SR & 0x80)) { }
    U2_DR = (uint32_t)c;
    /* console TXE readiness is a host artifact (file chardev), not
     * modelled baud; keep its jitter out of the time ledger */
    last_cvr = STK_CVR;
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

/* =================== bridge link (USART1) =================== */
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

static uint32_t last_sda = 1;
static uint32_t alert_lvl = 0;
static volatile int alert_flag = 0;

static void read_ack(void)              /* "K <sda> <alert>\n" */
{
    char c; int field = 0; uint32_t v[2] = {1, 0};
    while ((c = u1_getc()) != '\n') {
        if (c == ' ') { if (field < 2) field++; }
        else if (c == '0' || c == '1') {
            if (field >= 1 && field <= 2) v[field - 1] = (uint32_t)(c - '0');
        }
    }
    last_sda = v[0];
    if (v[1] && !alert_lvl) alert_flag = 1;   /* rising edge dispatch */
    alert_lvl = v[1];
    /* The ack-wait is HARNESS time, not firmware time (on silicon a
     * GPIO write completes instantly; there is no ack).  Its
     * duration also depends on host socket scheduling, so metering
     * it would leak wall-clock jitter into virtual time and break
     * determinism.  Reset the ruler: the wait costs nothing. */
    last_cvr = STK_CVR;
}

/* =================== bench-like time metering =================== */
static uint32_t tick_rem;          /* unaccounted systick ticks     */
static uint64_t t_board_ns;        /* board time we have granted    */

static void time_init(void)
{
    STK_RVR = 0x00FFFFFFu;
    STK_CVR = 0;
    STK_CSR = 0x5;                 /* ENABLE | CLKSOURCE=CPU        */
    last_cvr = STK_CVR;
}
static uint32_t ticks_elapsed(void)    /* since last call, wrap-safe */
{
    uint32_t now = STK_CVR;
    uint32_t d = (last_cvr - now) & 0x00FFFFFFu;   /* down-counter  */
    last_cvr = now;
    return d;
}
/* grant the board every full microsecond of our measured execution */
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
/* wait in BOARD time, beaconing every ~QUANTUM_US of execution */
static void wait_until_ns(uint64_t t_ns)
{
    while (t_board_ns < t_ns && !alert_flag) {
        /* burn roughly one quantum of real execution, then sync */
        while (tick_rem + ((last_cvr - STK_CVR) & 0x00FFFFFFu)
               < QUANTUM_US * TICKS_PER_US) { }
        sync_time();
    }
}

static void put_t(void)
{
    puts_("[fw t=");
    putu((uint32_t)(t_board_ns / 1000000u));
    putc_('.');
    putu((uint32_t)((t_board_ns / 100000u) % 10u));
    puts_("ms] ");
}

/* =================== bit-banged I2C =================== */
static void pins(int scl, int sda_rel)
{
    sync_time();                   /* flush: edge lands at the right instant */
    u1_putc('S'); u1_putc(' ');
    u1_putc((char)('0' + (scl & 1))); u1_putc(' ');
    u1_putc((char)('0' + (sda_rel ? 0 : 1))); u1_putc('\n');
    read_ack();
}
/* quarter-bit: real execution cost, ~2.5 us of virtual time */
static void qdel(void)
{
    uint32_t t0 = STK_CVR;
    while (((t0 - STK_CVR) & 0x00FFFFFFu) < (5u * TICKS_PER_US) / 2u) { }
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
    int ack = !(last_sda & 1);
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
        v = (uint8_t)((v << 1) | (last_sda & 1));
        qdel();
        pins(0, 1); qdel();
    }
    pins(0, ack ? 0 : 1); qdel();
    pins(1, ack ? 0 : 1); qdel(); qdel();
    pins(0, 1); qdel();
    return v;
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

static int nacks = 0;

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

static void qemu_exit(void)
{
    register uint32_t r0 asm("r0") = 0x18;
    register uint32_t r1 asm("r1") = 0x20026;
    asm volatile("bkpt 0xAB" :: "r"(r0), "r"(r1) : "memory");
}

/* =================== the mission =================== */
int main(void)
{
    uint8_t d[4];

    U1_CR1 = CR1_EN;
    U2_CR1 = CR1_EN;
    time_init();

    /* calibration self-check: ticks across a fixed spin */
    {
        uint32_t t0 = STK_CVR;
        for (volatile int i = 0; i < 1000; i++) { }
        uint32_t dt = (t0 - STK_CVR) & 0x00FFFFFFu;
        puts_("\n[fw] bench-like time on QEMU+icount; 1000-spin = ");
        putu(dt); puts_(" systick ticks\n");
    }

    wr16(R_CUV, 2800);
    wr16(R_COV, 4250);
#ifdef FAULT_OCD_SWAP
    {   /* INJECTED BUG: byte-swapped threshold write */
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
    put_t(); puts_("ALERT dispatch armed; polling for telemetry only\n");

#ifdef FAULT_REG_OFF1
#define R_CELLS_RD (R_CELLS + 1)
#else
#define R_CELLS_RD R_CELLS
#endif

    int tripped = 0, recovered = 0, bus_warned = 0, tele_warned = 0;
    uint64_t next_poll = t_board_ns + 2000000u;
    for (int loop = 0; loop < 60 && !recovered; loop++) {
        wait_until_ns(next_poll);
        next_poll = t_board_ns + 2000000u;

        if (alert_flag && !tripped) {
            tripped = 1;
            uint64_t t_seen = t_board_ns;
            uint8_t ss;
            afe_rd(R_SAFETY, &ss, 1);
            put_t(); puts_("*** ALERT dispatched at t=");
            putu((uint32_t)(t_seen / 1000u));
            puts_("us ss=0x"); putu(ss);
            puts_(" -- OCD TRIP seen over I2C -- current stopped by the AFE\n");
            alert_flag = 0;
            wait_until_ns(42000000u);
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
    sync_time();
    u1_putc('F'); u1_putc('\n');
    read_ack();
    qemu_exit();
    for (;;) { }
}
