/*======================================================================
 * xezim_bridge.c -- the xezim half of the Renode<->xezim co-simulation
 * bridge.  TCP server; Renode's XezimBridge peripheral is the client.
 *
 * Lockstep protocol (text lines):
 *   client -> "S <scl> <sda_pull>\n"   set the MCU-driven pins
 *   client -> "A <ns>\n"               advance board time by ns
 *   client -> "F\n"                    finish the simulation
 *   server -> "K <sda>\n"              ack, carrying SDA as sampled
 *                                      AFTER the command took effect
 *
 * The ack for command N is sent at the top of the call that fetches
 * command N+1, by which point the SV side has applied/advanced and
 * re-sampled the bus.  xezim's clock therefore moves ONLY on 'A'
 * commands: the firmware's own delays are the sole source of board
 * time.  Blocking recv() is fine -- the whole simulator should idle
 * until the SoC does something.
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
static char buf[128];
static int blen = 0;

SV_PUBLIC int br_init(int port)
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
    fprintf(stderr, "[xezim-bridge] listening on 127.0.0.1:%d\n", port);
    return 0;
}

static int read_line(void)
{
    /* fill buf with one \n-terminated line */
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

/* Fetch the next command.  sda_now = bus as currently sampled by SV.
 * Returns 0=SET 1=ADV 2=FIN (also on socket loss).                  */
SV_PUBLIC int br_next(int sda_now, int *scl_o, int *sda_o, int *ns_o)
{
    *scl_o = 1; *sda_o = 0; *ns_o = 0;

    if (first) {
        int one = 1;
        csock = accept(lsock, NULL, NULL);
        if (csock < 0) return 2;
        setsockopt(csock, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        fprintf(stderr, "[xezim-bridge] Renode connected\n");
        first = 0;
    } else {
        char ack[16];
        int n = snprintf(ack, sizeof ack, "K %d\n", sda_now & 1);
        if (send(csock, ack, (size_t)n, 0) != n) return 2;
    }

    if (read_line() < 0) {
        fprintf(stderr, "[xezim-bridge] connection closed\n");
        return 2;
    }
    switch (buf[0]) {
    case 'S': {
        int s = 1, d = 0;
        sscanf(buf + 1, "%d %d", &s, &d);
        *scl_o = s & 1; *sda_o = d & 1;
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
        send(csock, "K 1\n", 4, 0);
        return 2;
    }
}
