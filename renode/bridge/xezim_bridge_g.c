/*======================================================================
 * xezim_bridge_g.c -- the GENERIC (protocol-agnostic) xezim half of
 * the co-simulation bridge.
 *
 * Where the earlier bridges named their wires (SCL, SDA), this one
 * carries PIN VECTORS: up to 32 firmware-driven output pins and up to
 * 32 board-driven input pins, as hex masks.  Any pin-level protocol
 * (I2C, SPI/HX71x, UART, 1-Wire, GPIO) rides the same three verbs:
 *
 *   client -> "S <out_hex>\n"   set the firmware-driven pins
 *   client -> "A <ns>\n"        advance board time
 *   client -> "F\n"             finish
 *   server -> "K <in_hex> <alert>\n"   ack, with the board-driven
 *             pins as sampled AFTER the command settled, plus ALERT
 *
 * The pin MAP (which bit is which wire) lives in the SV top that
 * instantiates pin_bridge, and in the firmware's HAL: the bridge
 * itself knows nothing about protocols.
 *====================================================================*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

#ifdef __GNUC__
#define SV_PUBLIC __attribute__((visibility("default")))
#else
#define SV_PUBLIC
#endif

static int lsock = -1, csock = -1;
static int first = 1;
static char buf[160];
static int blen = 0;

SV_PUBLIC int brg_init(int port)
{
    struct sockaddr_in a;
    int one = 1;
    lsock = socket(AF_INET, SOCK_STREAM, 0);
    if (lsock < 0) return -1;
    setsockopt(lsock, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons((unsigned short)port);
    if (bind(lsock, (struct sockaddr *)&a, sizeof a) < 0) return -2;
    if (listen(lsock, 1) < 0) return -3;
    fprintf(stderr, "[xezim-bridge-g] listening on 127.0.0.1:%d\n", port);
    return 0;
}

static int read_line(void)
{
    blen = 0;
    while (blen < (int)sizeof buf - 1) {
        char c;
        ssize_t r = recv(csock, &c, 1, 0);
        if (r <= 0) return -1;
        if (c == '\n') { buf[blen] = 0; return 0; }
        if (c != '\r') buf[blen++] = c;
    }
    return -1;
}

/* Fetch the next command.  in_now = board-driven pins as currently
 * sampled; returns 0=SET 1=ADV 2=FIN. */
SV_PUBLIC int brg_next(int in_now, int alert_now, int *out_o, int *ns_o)
{
    *out_o = 0; *ns_o = 0;

    if (first) {
        int one = 1;
        csock = accept(lsock, NULL, NULL);
        if (csock < 0) return 2;
        setsockopt(csock, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        fprintf(stderr, "[xezim-bridge-g] client connected\n");
        first = 0;
    } else {
        char ack[48];
        int n = snprintf(ack, sizeof ack, "K %x %d\n",
                         (unsigned)in_now, alert_now & 1);
        if (send(csock, ack, (size_t)n, 0) != n) return 2;
    }

    if (read_line() < 0) {
        fprintf(stderr, "[xezim-bridge-g] connection closed\n");
        return 2;
    }
    switch (buf[0]) {
    case 'S': {
        unsigned v = 0;
        sscanf(buf + 1, "%x", &v);
        *out_o = (int)v;
        return 0;
    }
    case 'A': {
        int ns = 0;
        sscanf(buf + 1, "%d", &ns);
        *ns_o = ns > 0 ? ns : 1;
        return 1;
    }
    case 'F':
    default:
        send(csock, "K 0 0\n", 6, 0);
        return 2;
    }
}
