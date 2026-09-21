// trace_tb -- drive tpu_core through one RUN_TILE and dump a full VCD.
//
// This is the ground truth for viz/: the real RTL, driven over the real byte
// protocol, with every internal signal recorded. viz/vcd_to_trace.py turns the
// VCD into a per-cycle JSON timeline, and viz/check_model.mjs replays the same
// inputs through the viewer's JavaScript model and demands they agree.
//
// Build with the sim-trace target in the root Makefile; run as:
//   trace_tb --w 1,2,3,... --a 1,2,... [--bias 0,0,0,0] -o out.vcd
// W is ARRAY_ROWS*NUM_COLS int8 row-major, A is M_TILE*ARRAY_ROWS int8
// row-major, bias is NUM_COLS int16.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "Vtpu_core.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#ifndef TB_ROWS
#define TB_ROWS 4
#endif
#ifndef TB_COLS
#define TB_COLS 4
#endif
#ifndef TB_MTILE
#define TB_MTILE 4
#endif

static constexpr int ROWS = TB_ROWS, COLS = TB_COLS, MTILE = TB_MTILE;
static constexpr uint8_t CMD_LOAD_BIAS = 0x02, CMD_RUN_TILE = 0x06;
static constexpr uint8_t FLAG_FIRST = 0x01, FLAG_LAST = 0x02;

struct Tb {
    Vtpu_core* dut = new Vtpu_core;
    VerilatedVcdC* tfp = new VerilatedVcdC;
    uint64_t t = 0;          // VCD time, in half-cycles
    uint64_t cycles = 0;
    std::vector<uint8_t> tx;

    void cycle(int n = 1) {
        for (int i = 0; i < n; i++) {
            dut->clk = 1; dut->eval(); tfp->dump(t++);
            if (dut->tx_valid) tx.push_back((uint8_t)dut->tx_data);
            dut->clk = 0; dut->eval(); tfp->dump(t++);
            cycles++;
        }
    }
    void send(uint8_t v) {
        dut->rx_data = v; dut->rx_valid = 1; cycle();
        dut->rx_valid = 0; cycle();
    }
    void frame(uint8_t cmd, const std::vector<uint8_t>& p) {
        cycle(16);                       // settle: TX FSM back to S_IDLE
        send(cmd); send((uint8_t)p.size());
        for (uint8_t b : p) send(b);
        // Wait for the response rather than a fixed delay, so the trace always
        // covers the whole pipeline pass however long it takes.
        size_t want = tx.size() + 2;
        for (int guard = 0; guard < 4000 && tx.size() < want; guard++) cycle();
        if (tx.size() >= want) {
            size_t len = tx[tx.size() - 1];
            for (int guard = 0; guard < 4000 && tx.size() < want + len; guard++) cycle();
        }
        cycle(16);
    }
};

static std::vector<int> parse_ints(const char* s) {
    std::vector<int> out;
    if (!s || !*s) return out;
    std::string cur;
    for (const char* p = s;; p++) {
        if (*p == ',' || *p == '\0') {
            if (!cur.empty()) out.push_back(atoi(cur.c_str()));
            cur.clear();
            if (*p == '\0') break;
        } else if (*p != ' ') {
            cur += *p;
        }
    }
    return out;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char *w_s = nullptr, *a_s = nullptr, *b_s = nullptr, *out = "trace.vcd";
    for (int i = 1; i < argc; i++) {
        std::string k = argv[i];
        if (k == "--w" && i + 1 < argc) w_s = argv[++i];
        else if (k == "--a" && i + 1 < argc) a_s = argv[++i];
        else if (k == "--bias" && i + 1 < argc) b_s = argv[++i];
        else if ((k == "-o" || k == "--out") && i + 1 < argc) out = argv[++i];
    }
    std::vector<int> w = parse_ints(w_s), a = parse_ints(a_s), b = parse_ints(b_s);
    if ((int)w.size() != ROWS * COLS) {
        fprintf(stderr, "--w needs %d values (got %zu)\n", ROWS * COLS, w.size());
        return 2;
    }
    if ((int)a.size() != MTILE * ROWS) {
        fprintf(stderr, "--a needs %d values (got %zu)\n", MTILE * ROWS, a.size());
        return 2;
    }
    if (b.empty()) b.assign(COLS, 0);
    if ((int)b.size() != COLS) {
        fprintf(stderr, "--bias needs %d values (got %zu)\n", COLS, b.size());
        return 2;
    }

    Verilated::traceEverOn(true);
    Tb tb;
    tb.dut->trace(tb.tfp, 99);
    tb.tfp->open(out);

    tb.dut->reset = 1; tb.dut->rx_valid = 0; tb.dut->rx_error = 0;
    tb.dut->rx_data = 0; tb.dut->tx_busy = 0;
    tb.dut->eval();
    tb.cycle(8);
    tb.dut->reset = 0;
    tb.cycle(4);

    std::vector<uint8_t> bp;
    for (int c = 0; c < COLS; c++) {
        uint16_t v = (uint16_t)(int16_t)b[c];
        bp.push_back(v & 0xFF); bp.push_back(v >> 8);
    }
    tb.frame(CMD_LOAD_BIAS, bp);

    size_t before = tb.tx.size();
    std::vector<uint8_t> rp{(uint8_t)(FLAG_FIRST | FLAG_LAST)};
    for (int v : w) rp.push_back((uint8_t)(int8_t)v);   // natural row-major
    for (int v : a) rp.push_back((uint8_t)(int8_t)v);
    tb.frame(CMD_RUN_TILE, rp);

    tb.tfp->close();

    // Echo the device's result so the extractor can assert the trace it is
    // about to render actually corresponds to a correct computation.
    printf("{\"cycles\":%llu,\"result\":[", (unsigned long long)tb.cycles);
    size_t i = before + 2;   // skip STATUS, LEN
    for (int m = 0; m < MTILE; m++)
        for (int c = 0; c < COLS; c++) {
            size_t idx = i + 2 * (m * COLS + c);
            int16_t v = (idx + 1 < tb.tx.size())
                        ? (int16_t)(tb.tx[idx] | (tb.tx[idx + 1] << 8)) : 0;
            printf("%s%d", (m || c) ? "," : "", v);
        }
    printf("]}\n");
    return 0;
}
