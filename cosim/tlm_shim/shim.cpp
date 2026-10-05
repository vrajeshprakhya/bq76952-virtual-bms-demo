//======================================================================
// shim.cpp -- the RNM board as a STANDARD TLM-2.0 TARGET.
//
// Three host processes:
//
//   QEMU (unmodified mainline, the same fw_qemu.elf and UART-chardev
//   line protocol as the plain QEMU backend)
//        | TCP, port 43603
//   THIS SHIM (SystemC / IEEE 1666):
//        qemu_uart_initiator  -- parses the firmware's S/A/F lines
//                                and issues real TLM-2.0 generic-
//                                payload transactions
//        | tlm_utils sockets, b_transport, sc_time
//        rnm_board_tlm        -- a tlm-2.0 TARGET whose register map
//                                is the bridge contract (PINS/SDA/
//                                ADV/FIN) and whose backend is the
//                                untouched xezim line-protocol server
//        | TCP, port 43601
//   XEZIM (the SV-RNM board, byte-for-byte the v1 server)
//
// The point of the construction: everything the firmware does to the
// board crosses a genuine TLM-2.0 boundary, so any TLM initiator
// (QBox, a remote-port endpoint, a vendor virtual platform) can
// drive the same board by binding to rnm_board_tlm's socket.  The
// shim's sc_time advances with every ADV, so the SystemC kernel's
// clock tracks board time exactly (the logic contract, expressed in
// IEEE 1666 vocabulary).
//
// Register map of the TLM target (word offsets from 0x0):
//   0x00 W  PINS   bit0 SCL, bit1 SDA_PULL
//   0x04 R  SDA    bus as of the last settled command
//   0x08 W  ADV    advance board time by <value> ns
//   0x0C W  FIN    end the board simulation
//======================================================================
#include <systemc>
#include <tlm>
#include <tlm_utils/simple_initiator_socket.h>
#include <tlm_utils/simple_target_socket.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

using namespace sc_core;

//---------------------------------------------------------------------
// small blocking line-oriented TCP helpers
//---------------------------------------------------------------------
static int tcp_connect(int port)
{
    int s = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons((unsigned short)port);
    for (int i = 0; i < 100; i++) {
        if (connect(s, (sockaddr *)&a, sizeof a) == 0) {
            int one = 1;
            setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
            return s;
        }
        usleep(100000);
    }
    return -1;
}
static int tcp_listen_accept(int port)
{
    int l = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons((unsigned short)port);
    if (bind(l, (sockaddr *)&a, sizeof a) < 0) return -1;
    if (listen(l, 1) < 0) return -1;
    fprintf(stderr, "[shim] listening for QEMU on 127.0.0.1:%d\n", port);
    int c = accept(l, nullptr, nullptr);
    setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    fprintf(stderr, "[shim] QEMU connected\n");
    return c;
}
static bool read_line(int fd, std::string &out)
{
    out.clear();
    char c;
    while (true) {
        ssize_t r = recv(fd, &c, 1, 0);
        if (r <= 0) return false;
        if (c == '\n') return true;
        if (c != '\r') out.push_back(c);
    }
}
static bool write_all(int fd, const std::string &s)
{
    return send(fd, s.data(), s.size(), 0) == (ssize_t)s.size();
}

//---------------------------------------------------------------------
// rnm_board_tlm: the SV-RNM board, presented as a TLM-2.0 target.
// Backend: the unchanged xezim line-protocol server.
//---------------------------------------------------------------------
struct rnm_board_tlm : sc_module
{
    tlm_utils::simple_target_socket<rnm_board_tlm> socket;

    rnm_board_tlm(sc_module_name n, int xezim_port)
        : sc_module(n), socket("socket"), port(xezim_port)
    {
        socket.register_b_transport(this, &rnm_board_tlm::b_transport);
    }

    void b_transport(tlm::tlm_generic_payload &gp, sc_time &delay)
    {
        if (fd < 0) {
            fd = tcp_connect(port);
            if (fd < 0)
                SC_REPORT_FATAL("rnm_board_tlm", "cannot reach xezim");
            fprintf(stderr, "[shim] connected to xezim board server\n");
        }
        const uint64_t addr = gp.get_address();
        uint32_t *data = reinterpret_cast<uint32_t *>(gp.get_data_ptr());
        gp.set_response_status(tlm::TLM_OK_RESPONSE);

        if (gp.is_read()) {
            if (addr == 0x04) { *data = last_sda; return; }
            *data = 0;
            return;
        }
        char cmd[48];
        switch (addr) {
        case 0x00:      // PINS
            snprintf(cmd, sizeof cmd, "S %u %u\n",
                     *data & 1u, (*data >> 1) & 1u);
            rpc(cmd);
            break;
        case 0x08:      // ADV: board time, and the SystemC clock, move
            snprintf(cmd, sizeof cmd, "A %u\n", *data);
            rpc(cmd);
            delay += sc_time((double)*data, SC_NS);
            break;
        case 0x0C:      // FIN
            rpc("F\n");
            finished = true;
            break;
        default:
            gp.set_response_status(tlm::TLM_ADDRESS_ERROR_RESPONSE);
        }
    }

    void rpc(const char *cmd)
    {
        std::string line;
        if (!write_all(fd, cmd) || !read_line(fd, line)) {
            SC_REPORT_FATAL("rnm_board_tlm", "xezim link lost");
        }
        // "K <sda>" (a trailing alert field, if present, is ignored)
        if (line.size() >= 3 && line[0] == 'K')
            last_sda = (line[2] == '1') ? 1u : 0u;
    }

    int      port;
    int      fd = -1;
    uint32_t last_sda = 1;
    bool     finished = false;
};

//---------------------------------------------------------------------
// qemu_uart_initiator: accepts the firmware's UART-chardev byte
// stream, parses the S/A/F lines, and issues TLM-2.0 transactions.
//---------------------------------------------------------------------
struct qemu_uart_initiator : sc_module
{
    tlm_utils::simple_initiator_socket<qemu_uart_initiator> socket;
    rnm_board_tlm *board;   // to observe 'finished'

    SC_HAS_PROCESS(qemu_uart_initiator);
    qemu_uart_initiator(sc_module_name n, int listen_port,
                        rnm_board_tlm *b)
        : sc_module(n), socket("socket"), board(b), port(listen_port)
    {
        SC_THREAD(run);
    }

    void txn(uint64_t addr, uint32_t value, bool is_write,
             uint32_t *readback)
    {
        tlm::tlm_generic_payload gp;
        sc_time delay = SC_ZERO_TIME;
        uint32_t data = value;
        gp.set_command(is_write ? tlm::TLM_WRITE_COMMAND
                                : tlm::TLM_READ_COMMAND);
        gp.set_address(addr);
        gp.set_data_ptr(reinterpret_cast<unsigned char *>(&data));
        gp.set_data_length(4);
        gp.set_streaming_width(4);
        gp.set_response_status(tlm::TLM_INCOMPLETE_RESPONSE);
        socket->b_transport(gp, delay);
        if (gp.get_response_status() != tlm::TLM_OK_RESPONSE)
            SC_REPORT_FATAL("qemu_uart_initiator", "transaction failed");
        wait(delay);    // the SystemC clock tracks board time
        if (readback) *readback = data;
    }

    void run()
    {
        int fd = tcp_listen_accept(port);
        if (fd < 0)
            SC_REPORT_FATAL("qemu_uart_initiator", "listen failed");
        std::string line;
        unsigned long n_txn = 0;
        while (read_line(fd, line)) {
            if (line.empty()) continue;
            uint32_t a = 0, b = 0, sda = 1;
            char buf[24];
            switch (line[0]) {
            case 'S':
                sscanf(line.c_str() + 1, "%u %u", &a, &b);
                txn(0x00, (a & 1u) | ((b & 1u) << 1), true, nullptr);
                txn(0x04, 0, false, &sda);
                n_txn += 2;
                break;
            case 'A':
                sscanf(line.c_str() + 1, "%u", &a);
                txn(0x08, a, true, nullptr);
                txn(0x04, 0, false, &sda);
                n_txn += 2;
                break;
            case 'F':
            default:
                txn(0x0C, 1, true, nullptr);
                n_txn += 1;
                break;
            }
            snprintf(buf, sizeof buf, "K %u\n", sda);
            if (!write_all(fd, buf)) break;
            if (board->finished) break;
        }
        fprintf(stderr,
                "[shim] done: %lu TLM-2.0 transactions, sc_time = %s\n",
                n_txn, sc_time_stamp().to_string().c_str());
        sc_stop();
    }

    int port;
};

//---------------------------------------------------------------------
int sc_main(int argc, char **argv)
{
    int qemu_port  = (argc > 1) ? atoi(argv[1]) : 43603;
    int xezim_port = (argc > 2) ? atoi(argv[2]) : 43601;

    rnm_board_tlm       board("rnm_board", xezim_port);
    qemu_uart_initiator qemu("qemu_side", qemu_port, &board);
    qemu.socket.bind(board.socket);

    fprintf(stderr, "[shim] IEEE 1666 TLM-2.0 shim: QEMU :%d -> "
                    "rnm_board_tlm -> xezim :%d\n",
            qemu_port, xezim_port);
    sc_start();
    return 0;
}
