/*======================================================================
 * xezim_bridge2.c -- v2 (virtual-time quantum coupling) xezim half.
 *
 * Same TCP line protocol as v1 with one extension: every ack carries
 * the ALERT level as well as SDA ("K <sda> <alert>\n").  The deeper
 * change is WHO sends 'A': in v1 the firmware declared its delays;
 * in v2 Renode's quantum engine sends 'A <ns>' as the emulated CPU's
 * own virtual time elapses (one sync per quantum, plus a flush
 * before every pin access).  Board time is therefore a consequence
 * of the firmware's real execution cost, not of its promises.
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

SV_PUBLIC int br2_init(int port)
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
    fprintf(stderr, "[xezim-bridge2] listening on 127.0.0.1:%d\n", port);
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

/* Fetch the next command.  Returns 0=SET 1=ADV 2=FIN. */
SV_PUBLIC int br2_next(int sda_now, int alert_now,
                       int *scl_o, int *sda_o, int *ns_o)
{
    *scl_o = 1; *sda_o = 0; *ns_o = 0;

    if (first) {
        int one = 1;
        csock = accept(lsock, NULL, NULL);
        if (csock < 0) return 2;
        setsockopt(csock, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        fprintf(stderr, "[xezim-bridge2] Renode connected\n");
        first = 0;
    } else {
        char ack[24];
        int n = snprintf(ack, sizeof ack, "K %d %d\n",
                         sda_now & 1, alert_now & 1);
        if (send(csock, ack, (size_t)n, 0) != n) return 2;
    }

    if (read_line() < 0) {
        fprintf(stderr, "[xezim-bridge2] connection closed\n");
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
        send(csock, "K 1 0\n", 6, 0);
        return 2;
    }
}
