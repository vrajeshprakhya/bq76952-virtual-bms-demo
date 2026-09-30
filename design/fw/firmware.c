/*======================================================================
 * firmware.c -- REAL host firmware for the virtual 6S BMS board
 * (STM32G0B1 class + BQ76952-class battery-monitor AFE).
 *
 * Tick-driven state machine stepped by mcu_virtual.sv through DPI once
 * per MCU clock (TICK_NS).  Unlike the previous three demos, the ONLY
 * pins this firmware owns are SCL and SDA: every measurement, every
 * protection threshold and every FET/balancing decision travels over a
 * bit-banged pin-level I2C bus (~400 kHz, open-drain SDA) to the AFE's
 * register map.  Renode swap-in point: replace the tick shim with an
 * STM32G0B1 machine whose I2C peripheral drives the same two pins.
 *
 * Division of labour (as on the real chip):
 *   - the AFE measures 6 cells / pack current / temperature and runs
 *     the hardware protection engine against thresholds in ITS RAM
 *   - this host firmware CONFIGURES those thresholds over I2C, polls
 *     measurements + safety/FET status every control loop, decides
 *     cell BALANCING (writes CB mask for the highest cell when the
 *     spread exceeds 50 mV, off below 20 mV), and clears the AFE's
 *     latched overcurrent after a host-level fault reset.
 *
 * Demo register map of the AFE (BQ76952-flavoured, simplified -- see
 * rnm/bq76952_rnm.sv):
 *   0x03      Safety Status A (RO): b0 CUV, b1 COV, b2 OCD, b3 OT
 *   0x14+2n   cell n+1 voltage, mV, LE (RO)
 *   0x3A/3B   pack current, mA, signed LE (RO)
 *   0x68/69   temperature, 0.1 C, signed LE (RO)
 *   0x7F      FET status (RO): b0 DSG, b1 CHG
 *   0x90/91   CUV threshold mV LE   (RW)     0x92/93  COV threshold
 *   0x94/95   OCD threshold mA LE   (RW)     0x96     protection enable
 *   0x97      FET allow (b0 DSG, b1 CHG)     0x98     CB active cells
 *   0x99      recover: write 1 clears the latched OCD (self-clearing)
 *====================================================================*/

#include <stdint.h>

#ifdef __GNUC__
#define SV_PUBLIC __attribute__((visibility("default")))
#else
#define SV_PUBLIC
#endif

/*--- policy constants ------------------------------------------------*/
#define AFE_ADDR     0x08
#define CUV_MV       2800
#define COV_MV       4250
#define OCD_MA       3000
#define BAL_START_MV 50
#define BAL_STOP_MV  20
#define LOOP_NS      2000000LL      /* 2 ms control loop */
#define QT_TICKS     12             /* quarter I2C bit (~415 kHz @50ns) */

enum fw_state { FW_IDLE = 0, FW_CONFIG = 1, FW_POLL = 2, FW_COMPUTE = 3,
                FW_WAIT = 4 };

/*--- configuration ----------------------------------------------------*/
static int tick_ns = 50;
static int go      = 0;
static int do_recover = 0;          /* host-level fault reset pending  */

/*======================================================================
 * Pin-level I2C master engine: a queue of primitive ops, advanced one
 * quarter-bit phase per several ticks.  SDA is open-drain: sda_pull=1
 * means "pull low", 0 means released.
 *====================================================================*/
enum { OP_START, OP_TX, OP_RX_ACK, OP_RX_NACK, OP_STOP };

static int pin_scl = 1, pin_sda_pull = 0;

#define QMAX 40
static struct { int op; int val; } q[QMAX];
static int q_len = 0, q_pc = 0;
static int ph = 0, bitn = 0, shreg = 0;
static uint8_t rx_buf[16];
static int rx_cnt = 0;
static int tick_in_ph = 0;

static void q_reset(void)            { q_len = 0; q_pc = 0; ph = 0; bitn = 0; rx_cnt = 0; }
static void q_push(int op, int val)  { if (q_len < QMAX) { q[q_len].op = op; q[q_len].val = val; q_len++; } }

/* queue helpers: whole register transactions */
static void q_wr(uint8_t reg, const uint8_t *d, int n)
{
    int i;
    q_push(OP_START, 0);
    q_push(OP_TX, AFE_ADDR << 1);
    q_push(OP_TX, reg);
    for (i = 0; i < n; i++) q_push(OP_TX, d[i]);
    q_push(OP_STOP, 0);
}
static void q_rd(uint8_t reg, int n)
{
    int i;
    q_push(OP_START, 0);
    q_push(OP_TX, AFE_ADDR << 1);
    q_push(OP_TX, reg);
    q_push(OP_START, 0);                    /* repeated start */
    q_push(OP_TX, (AFE_ADDR << 1) | 1);
    for (i = 0; i < n - 1; i++) q_push(OP_RX_ACK, 0);
    q_push(OP_RX_NACK, 0);
    q_push(OP_STOP, 0);
}

/* advance the engine one PHASE; returns 1 while the queue is busy.
 * Each op is a sequence of quarter-bit phases.                        */
static int i2c_phase(int sda_in)
{
    if (q_pc >= q_len) return 0;

    switch (q[q_pc].op) {

    case OP_START:              /* sda high->low while scl high        */
        switch (ph++) {
        case 0: pin_sda_pull = 0; pin_scl = 1; break;
        case 1: pin_sda_pull = 1; break;
        case 2: pin_scl = 0; ph = 0; q_pc++; break;
        }
        break;

    case OP_STOP:               /* sda low->high while scl high        */
        switch (ph++) {
        case 0: pin_scl = 0; pin_sda_pull = 1; break;
        case 1: pin_scl = 1; break;
        case 2: pin_sda_pull = 0; ph = 0; q_pc++; break;
        }
        break;

    case OP_TX:                 /* 8 data bits + ack slot              */
        switch (ph) {
        case 0:
            if (bitn == 0) shreg = q[q_pc].val;
            pin_scl = 0;
            if (bitn < 8) pin_sda_pull = !((shreg >> (7 - bitn)) & 1);
            else          pin_sda_pull = 0;          /* release: ack   */
            ph = 1; break;
        case 1: pin_scl = 1; ph = 2; break;
        case 2: /* (slave ack sampled here on bit 8; ignored in demo)  */
            ph = 3; break;
        case 3:
            pin_scl = 0; ph = 0;
            if (++bitn > 8) { bitn = 0; q_pc++; }
            break;
        }
        break;

    case OP_RX_ACK:
    case OP_RX_NACK:            /* 8 read bits + master ack/nack       */
        switch (ph) {
        case 0:
            pin_scl = 0;
            if (bitn < 8) pin_sda_pull = 0;          /* release for rx */
            else pin_sda_pull = (q[q_pc].op == OP_RX_ACK);
            ph = 1; break;
        case 1: pin_scl = 1; ph = 2; break;
        case 2:
            if (bitn < 8) shreg = (shreg << 1) | (sda_in & 1);
            ph = 3; break;
        case 3:
            pin_scl = 0; ph = 0;
            if (++bitn > 8) {
                bitn = 0;
                if (rx_cnt < (int)sizeof(rx_buf)) rx_buf[rx_cnt++] = (uint8_t)shreg;
                shreg = 0;
                q_pc++;
            }
            break;
        }
        break;
    }
    return 1;
}

/*======================================================================
 * The host BMS application
 *====================================================================*/
static enum fw_state state = FW_IDLE;
static long long loop_left_ns = 0;
static int cfg_step = 0, poll_step = 0;

static int cell_mv[6];
static int pack_ma = 0, t_c10 = 250;
static int safety = 0, fets = 3;
static int min_mv = 0, max_mv = 0, delta_mv = 0, max_idx = 0;
static int cb_cur = 0;
static int loop_count = 0;

static void start_config(void)
{
    static uint8_t d[2];
    q_reset();
    d[0] = CUV_MV & 0xFF; d[1] = CUV_MV >> 8;  q_wr(0x90, d, 2);
    { uint8_t c[2] = { COV_MV & 0xFF, COV_MV >> 8 }; q_wr(0x92, c, 2); }
    { uint8_t o[2] = { OCD_MA & 0xFF, OCD_MA >> 8 }; q_wr(0x94, o, 2); }
    { uint8_t e = 0x0F;  q_wr(0x96, &e, 1); }   /* enable all          */
    { uint8_t f = 0x03;  q_wr(0x97, &f, 1); }   /* allow both FETs     */
    { uint8_t z = 0x00;  q_wr(0x98, &z, 1); }   /* balancing off       */
    cb_cur = 0;
    if (do_recover) { uint8_t r = 0x01; q_wr(0x99, &r, 1); do_recover = 0; }
}

static void compute(void)
{
    int i, want_cb;
    min_mv = 99999; max_mv = -1; max_idx = 0;
    for (i = 0; i < 6; i++) {
        if (cell_mv[i] < min_mv) min_mv = cell_mv[i];
        if (cell_mv[i] > max_mv) { max_mv = cell_mv[i]; max_idx = i; }
    }
    delta_mv = max_mv - min_mv;

    /* balancing policy: bleed the highest cell, with hysteresis */
    want_cb = cb_cur;
    if (safety != 0)                 want_cb = 0;
    else if (delta_mv > BAL_START_MV) want_cb = 1 << max_idx;
    else if (delta_mv < BAL_STOP_MV)  want_cb = 0;

    if (want_cb != cb_cur) {
        uint8_t b = (uint8_t)want_cb;
        q_reset();
        q_wr(0x98, &b, 1);
        cb_cur = want_cb;
    }
}

/*--- DPI surface ------------------------------------------------------*/

SV_PUBLIC void fw_set_tick_ns(int t) { if (t > 0) tick_ns = t; }

SV_PUBLIC void fw_configure(int reset_faults, int run)
{
    go = run;
    if (reset_faults) do_recover = 1;
    /* re-run the config sequence at the next loop boundary */
    if (run && state != FW_IDLE) { /* let the current loop finish */ }
    if (!run) { state = FW_IDLE; pin_scl = 1; pin_sda_pull = 0; }
    cfg_step = -1;      /* flag: config wanted */
}

SV_PUBLIC int fw_get_cell_mv(int i)   { return (i >= 0 && i < 6) ? cell_mv[i] : 0; }
SV_PUBLIC int fw_get_ma(void)         { return pack_ma; }
SV_PUBLIC int fw_get_t_c10(void)      { return t_c10; }
SV_PUBLIC int fw_get_safety(void)     { return safety; }
SV_PUBLIC int fw_get_fets(void)       { return fets; }
SV_PUBLIC int fw_get_cb(void)         { return cb_cur; }
SV_PUBLIC int fw_get_delta(void)      { return delta_mv; }
SV_PUBLIC int fw_get_loop_count(void) { return loop_count; }

/* One MCU clock tick.  sda_in = resolved open-drain bus this cycle.  */
SV_PUBLIC void fw_tick(int sda_in, int *scl, int *sda_pull,
                       int *frame_done, int *fw_state)
{
    int fd = 0;

    if (loop_left_ns > 0) loop_left_ns -= tick_ns;

    /* one I2C quarter-bit phase every QT_TICKS ticks */
    if (++tick_in_ph >= QT_TICKS) {
        tick_in_ph = 0;

        switch (state) {

        case FW_IDLE:
            if (go) { start_config(); state = FW_CONFIG; }
            break;

        case FW_CONFIG:
            if (!i2c_phase(sda_in)) { poll_step = 0; q_reset(); state = FW_POLL; }
            break;

        case FW_POLL:
            if (!i2c_phase(sda_in)) {
                /* previous read finished: harvest, then queue the next */
                switch (poll_step++) {
                case 0: q_rd(0x14, 12); break;              /* cells    */
                case 1: {
                    int i;
                    for (i = 0; i < 6; i++)
                        cell_mv[i] = rx_buf[2*i] | (rx_buf[2*i+1] << 8);
                    q_reset(); q_rd(0x3A, 2); break;        /* current  */
                }
                case 2:
                    pack_ma = (int16_t)(rx_buf[0] | (rx_buf[1] << 8));
                    q_reset(); q_rd(0x68, 2); break;        /* temp     */
                case 3:
                    t_c10 = (int16_t)(rx_buf[0] | (rx_buf[1] << 8));
                    q_reset(); q_rd(0x03, 1); break;        /* safety   */
                case 4:
                    safety = rx_buf[0];
                    q_reset(); q_rd(0x7F, 1); break;        /* FETs     */
                case 5:
                    fets = rx_buf[0];
                    state = FW_COMPUTE; break;
                }
                if (state == FW_POLL && poll_step <= 5 && q_len == 0)
                    ;   /* next call runs the queued transaction */
            }
            break;

        case FW_COMPUTE:
            q_reset();
            compute();                       /* may queue a CB write    */
            loop_count++;
            fd = 1;
            loop_left_ns = LOOP_NS;
            state = FW_WAIT;
            break;

        case FW_WAIT:
            i2c_phase(sda_in);               /* drain a pending CB write */
            if (loop_left_ns <= 0 && q_pc >= q_len) {
                if (cfg_step == -1) { start_config(); cfg_step = 0; state = FW_CONFIG; }
                else                { poll_step = 0; q_reset(); state = FW_POLL; }
            }
            break;
        }
    }

    *scl = pin_scl; *sda_pull = pin_sda_pull;
    *frame_done = fd; *fw_state = (int)state;
}
