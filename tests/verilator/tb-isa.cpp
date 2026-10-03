// tpu_top as a register-level transport for host/tpu/isa_device.py.
// stdin carries 'W' addr u32 (write, no reply), 'R' addr (read, 4-byte reply),
// 'D' addr u32 len u32 bytes (DDR3 write, no reply), 'G' addr u32 len u32 (DDR3
// read, len bytes back), 'M' mode (DDR3 timing, no reply), 'T' n u32 (run n
// cycles, no reply), 'V' len u16 path (start a VCD of every cycle at path, or
// with len 0 stop it; a TB_TRACE build only, no reply) and 'Q' (quit); on start
// it writes its build parameters as 5 u32 words.
// the DDR3 model behind tpu_top's master is the FPGA-to-SDRAM port as the core
// sees it: one in-order port, at most 14 bursts pending, no read backpressure,
// single-beat writes with byteenables. a read's data is what DDR3 held when the
// read was accepted. mode 1 (the default) gives random waitrequest, latency and
// gaps between beats; mode 0 answers every command at once, 10 cycles to the
// first beat, beats back to back; mode k >= 2 is the same with k cycles
#include <cstdint>
#include <cstdio>
#include <algorithm>
#include <cstdlib>
#include <deque>
#include <memory>
#include <random>
#include <string>
#include <unordered_map>
#include <vector>
#include "Vtpu_top.h"

#ifndef TB_BEAT_BYTES
#define TB_BEAT_BYTES 16         // the DDR3 port's data width: 16 (128-bit) or 32 (256-bit)
#endif
static constexpr int BEAT = TB_BEAT_BYTES;
#include "verilated.h"
#ifdef TB_TRACE
#include "verilated_vcd_c.h"
#endif

static std::unique_ptr<Vtpu_top> dut;

#ifdef TB_TRACE
// one sample per clock, just before the rising edge, timestamped with the cycle:
// the registers as they stand and every input that edge is about to take
static std::unique_ptr<VerilatedVcdC> vcd;
static bool vcd_on = false;
#endif

namespace ddr {
    std::unordered_map<uint32_t, std::vector<uint8_t>> pages;   // 4 KB pages, zero until written
    struct Burst { std::vector<uint8_t> data; int beats; uint64_t ready; };
    std::deque<Burst> pending;
    int sent = 0;
    bool random_timing = true;
    int latency = 10;
    std::mt19937 rng(1);
    uint64_t now = 0;
    bool held = false;
    uint32_t held_address = 0;
    int held_count = 0;

    uint8_t byte(uint32_t a) {
        auto p = pages.find(a >> 12);
        return p == pages.end() ? 0 : p->second[a & 0xFFF];
    }
    // whole runs within a page at a time: Qwen's 494 MB of weights go through here
    void write(uint32_t a, const uint8_t* data, size_t n) {
        while (n) {
            size_t k = std::min<size_t>(n, 4096 - (a & 0xFFF));
            auto& page = pages[a >> 12];
            if (page.empty()) page.resize(4096);
            std::copy(data, data + k, page.begin() + (a & 0xFFF));
            a += k; data += k; n -= k;
        }
    }
    void write(uint32_t a, const std::vector<uint8_t>& data) { write(a, data.data(), data.size()); }
    void read(uint32_t a, uint8_t* out, size_t n) {
        while (n) {
            size_t k = std::min<size_t>(n, 4096 - (a & 0xFFF));
            auto p = pages.find(a >> 12);
            if (p == pages.end()) std::fill(out, out + k, 0);
            else std::copy(p->second.begin() + (a & 0xFFF), p->second.begin() + (a & 0xFFF) + k, out);
            a += k; out += k; n -= k;
        }
    }
    [[noreturn]] void fail(const char* what) {
        fprintf(stderr, "tb_isa: DDR3 port: %s (cycle %llu)\n", what, (unsigned long long)now);
        exit(3);
    }

    // the slave's outputs for this cycle, before the clock edge
    void drive() {
        dut->avm_waitrequest = pending.size() >= 14 || (random_timing && rng() % 4 == 0);
        bool beat = !pending.empty() && pending.front().ready <= now && !(random_timing && rng() % 5 == 0);
        dut->avm_readdatavalid = beat;
        if (beat) {
            const uint8_t* d = pending.front().data.data() + BEAT * sent;
            for (int lane = 0; lane < BEAT / 4; lane++) {
                uint32_t w = 0;
                for (int b = 3; b >= 0; b--) w = w << 8 | d[4 * lane + b];
                dut->avm_readdata[lane] = w;
            }
        }
    }
    // the master's command, sampled before the edge; then the beat retires
    void sample() {
        bool command = dut->avm_read || dut->avm_write;
        if (dut->avm_read && dut->avm_write) fail("read and write together");
        if (held && !command) fail("command dropped under waitrequest");
        if (command && held && (dut->avm_address != held_address || dut->avm_burstcount != held_count))
            fail("command changed under waitrequest");
        held = command && dut->avm_waitrequest;
        held_address = dut->avm_address;
        held_count = dut->avm_burstcount;
        if (command && !dut->avm_waitrequest) {
            if (dut->avm_address % BEAT || dut->avm_burstcount == 0 || dut->avm_burstcount > 128
                || (dut->avm_write && dut->avm_burstcount != 1))
                fail("misaligned address or bad burstcount");
            if (dut->avm_read) {
                Burst b{std::vector<uint8_t>(BEAT * dut->avm_burstcount), dut->avm_burstcount,
                        now + (random_timing ? 4 + rng() % 30 : latency)};
                read(dut->avm_address, b.data.data(), b.data.size());
                pending.push_back(std::move(b));
            } else {
                std::vector<uint8_t> one(1);
                for (int i = 0; i < BEAT; i++)
                    if ((uint64_t)dut->avm_byteenable >> i & 1) {
                        one[0] = dut->avm_writedata[i / 4] >> (8 * (i % 4));
                        write(dut->avm_address + i, one);
                    }
            }
        }
        if (dut->avm_readdatavalid && ++sent == pending.front().beats) {
            pending.pop_front();
            sent = 0;
        }
        now++;
    }
}

static void tick() {
    dut->clk = 0;
    ddr::drive();
    dut->eval();
#ifdef TB_TRACE
    if (vcd_on) vcd->dump(ddr::now);
#endif
    ddr::sample();
    dut->clk = 1;
    dut->eval();
}

static bool get(void* p, size_t n) { return fread(p, 1, n, stdin) == n; }

static void put32(uint32_t v) {
    fwrite(&v, 4, 1, stdout);   // little-endian host
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = std::make_unique<Vtpu_top>();
    dut->reset_n = 0;
    dut->avs_read = 0;
    dut->avs_write = 0;
    dut->avm_waitrequest = 1;
    dut->avm_readdatavalid = 0;
    dut->avm_readdatavalid = 0;
    for (int i = 0; i < 4; i++) tick();
    dut->reset_n = 1;
    for (int i = 0; i < 300; i++) tick();   // past the 256-cycle power-on reset

    const uint32_t params[5] = {TB_N, TB_WMEM_ROWS, TB_UB_DEPTH, TB_ACC_DEPTH, TB_PARAM_DEPTH};
    for (uint32_t p : params) put32(p);
    fflush(stdout);

    for (;;) {
        uint8_t cmd;
        if (!get(&cmd, 1) || cmd == 'Q') break;
        if (cmd == 'D') {
            uint32_t address, length;
            if (!get(&address, 4) || !get(&length, 4)) break;
            std::vector<uint8_t> data(length);
            if (length && !get(data.data(), length)) break;
            ddr::write(address, data);
            continue;
        }
        if (cmd == 'G') {
            uint32_t address, length;
            if (!get(&address, 4) || !get(&length, 4)) break;
            std::vector<uint8_t> data(length);
            ddr::read(address, data.data(), length);
            fwrite(data.data(), 1, length, stdout);
            fflush(stdout);
            continue;
        }
        if (cmd == 'T') {                    // let the core run: the clock only moves when told
            uint32_t cycles;
            if (!get(&cycles, 4)) break;
            for (uint32_t i = 0; i < cycles; i++) tick();
            continue;
        }
        if (cmd == 'V') {
            uint16_t length;
            if (!get(&length, 2)) break;
            std::string path(length, '\0');
            if (length && !get(path.data(), length)) break;
#ifdef TB_TRACE
            if (length) {
                if (vcd) { fprintf(stderr, "tb_isa: one VCD per run\n"); return 2; }
                Verilated::traceEverOn(true);
                vcd = std::make_unique<VerilatedVcdC>();
                dut->trace(vcd.get(), 99);
                vcd->open(path.c_str());
                vcd_on = true;
            } else if (vcd) {
                vcd_on = false;
                vcd->close();
            }
#else
            if (length) { fprintf(stderr, "tb_isa: built without TB_TRACE (make viz-sim)\n"); return 2; }
#endif
            continue;
        }
        if (cmd == 'M') {
            uint8_t mode;
            if (!get(&mode, 1)) break;
            ddr::random_timing = mode == 1;
            ddr::latency = mode >= 2 ? mode : 10;
            continue;
        }
        uint8_t addr;
        if (!get(&addr, 1)) break;
        if (cmd == 'W') {
            uint32_t data;
            if (!get(&data, 4)) break;
            dut->avs_address = addr;
            dut->avs_writedata = data;
            dut->avs_write = 1;
            dut->eval();
            while (dut->avs_waitrequest) {   // FIFO full: the engines drain it
                tick();
                dut->eval();
            }
            tick();
            dut->avs_write = 0;
        } else if (cmd == 'R') {
            dut->avs_address = addr;
            dut->avs_read = 1;
            tick();                          // fixed read latency 1
            dut->avs_read = 0;
            dut->eval();
            put32(dut->avs_readdata);
            fflush(stdout);
        } else {
            dut.reset();
            return 2;
        }
    }
    dut->final();
#ifdef TB_TRACE
    if (vcd) vcd->close();
    vcd.reset();
#endif
    dut.reset();   // before Verilator's own statics go, or exit aborts on a mutex
    return 0;
}
