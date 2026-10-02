// tpu_top as a register-level transport for host/tpu/isa_device.py.
// stdin carries 'W' addr u32 (write, no reply), 'R' addr (read, 4-byte reply),
// 'D' addr u32 len u32 bytes (DDR3 write, no reply), 'M' mode (DDR3 timing, no
// reply) and 'Q' (quit); on start it writes its build parameters as 5 u32 words.
// the DDR3 model behind tpu_top's master is the FPGA-to-SDRAM port as the core
// sees it: at most 14 bursts pending, no read backpressure. mode 1 (the default)
// gives random waitrequest, latency and gaps between beats; mode 0 answers every
// command at once with a fixed latency and back-to-back beats
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <memory>
#include <random>
#include <unordered_map>
#include <vector>
#include "Vtpu_top.h"
#include "verilated.h"

static std::unique_ptr<Vtpu_top> dut;

namespace ddr {
    std::unordered_map<uint32_t, std::vector<uint8_t>> pages;   // 4 KB pages, zero until written
    struct Burst { uint32_t address; int beats; uint64_t ready; };
    std::deque<Burst> pending;
    int sent = 0;
    bool random_timing = true;
    std::mt19937 rng(1);
    uint64_t now = 0;
    bool held = false;
    uint32_t held_address = 0;
    int held_count = 0;

    uint8_t byte(uint32_t a) {
        auto p = pages.find(a >> 12);
        return p == pages.end() ? 0 : p->second[a & 0xFFF];
    }
    void write(uint32_t a, const std::vector<uint8_t>& data) {
        for (size_t i = 0; i < data.size(); i++) {
            auto& page = pages[(a + i) >> 12];
            if (page.empty()) page.resize(4096);
            page[(a + i) & 0xFFF] = data[i];
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
            uint32_t a = pending.front().address + 16 * sent;
            for (int lane = 0; lane < 4; lane++) {
                uint32_t w = 0;
                for (int b = 3; b >= 0; b--) w = w << 8 | byte(a + 4 * lane + b);
                dut->avm_readdata[lane] = w;
            }
        }
    }
    // the master's command, sampled before the edge; then the beat retires
    void sample() {
        if (dut->avm_read && held && (dut->avm_address != held_address || dut->avm_burstcount != held_count))
            fail("command changed under waitrequest");
        held = dut->avm_read && dut->avm_waitrequest;
        held_address = dut->avm_address;
        held_count = dut->avm_burstcount;
        if (dut->avm_read && !dut->avm_waitrequest) {
            if (dut->avm_address % 16 || dut->avm_burstcount == 0 || dut->avm_burstcount > 128)
                fail("misaligned address or bad burstcount");
            pending.push_back({dut->avm_address, dut->avm_burstcount,
                               now + (random_timing ? 4 + rng() % 30 : 10)});
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
        if (cmd == 'M') {
            uint8_t mode;
            if (!get(&mode, 1)) break;
            ddr::random_timing = mode != 0;
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
    dut.reset();   // before Verilator's own statics go, or exit aborts on a mutex
    return 0;
}
