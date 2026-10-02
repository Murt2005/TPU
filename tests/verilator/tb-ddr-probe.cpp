// ddr_probe against a model of the HPS's FPGA-to-SDRAM Avalon port: random
// waitrequest, at most 14 pending bursts, random latency and gaps between beats.
// every run must receive every beat, match the checksum the model computes, keep
// its command stable under waitrequest and never exceed OUTSTANDING
#include <cstdint>
#include <cstdio>
#include <deque>
#include <memory>
#include <random>
#include "Vddr_probe.h"
#include "verilated.h"

static uint32_t word_at(uint32_t byte_address) {   // DDR contents: a hash of the address
    uint32_t x = byte_address * 0x9E3779B1u;
    return x ^ (x >> 15);
}

struct Burst { uint32_t address; int beats; uint64_t ready; };

int main(int argc, char** argv) {
    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);
    auto dut = std::make_unique<Vddr_probe>(ctx.get());
    std::mt19937 rng(1);
    uint64_t now = 0;
    std::deque<Burst> pending;
    int sent_in_burst = 0, in_flight = 0, failures = 0;
    bool held = false;
    uint32_t held_address = 0;

    auto tick = [&] {
        dut->clk = 0; dut->eval();
        // the slave's outputs for this cycle
        dut->avm_waitrequest = pending.size() >= 14 || rng() % 4 == 0;
        bool beat = !pending.empty() && pending.front().ready <= now && rng() % 5 != 0;
        dut->avm_readdatavalid = beat;
        if (beat) {
            uint32_t a = pending.front().address + 16 * sent_in_burst;
            for (int lane = 0; lane < 4; lane++) dut->avm_readdata[lane] = word_at(a + 4 * lane);
        }
        dut->eval();
        // protocol checks on the master's command
        if (dut->avm_read && held && dut->avm_address != held_address) {
            printf("  address changed under waitrequest\n"); failures++;
        }
        held = dut->avm_read && dut->avm_waitrequest;
        held_address = dut->avm_address;
        bool accepted = dut->avm_read && !dut->avm_waitrequest;
        if (accepted) {
            pending.push_back({dut->avm_address, dut->avm_burstcount, now + 4 + rng() % 40});
            in_flight++;
        }
        if (beat && ++sent_in_burst == pending.front().beats) {
            pending.pop_front(); sent_in_burst = 0; in_flight--;
        }
        dut->clk = 1; dut->eval();
        now++;
        return in_flight;
    };
    auto write = [&](int reg, uint32_t value) {
        dut->avs_address = reg; dut->avs_writedata = value; dut->avs_write = 1; tick(); dut->avs_write = 0;
    };
    auto read = [&](int reg) {
        dut->avs_address = reg; dut->avs_read = 1; tick(); dut->avs_read = 0; return (uint32_t)dut->avs_readdata;
    };

    dut->reset_n = 0; tick(); tick(); dut->reset_n = 1; tick();
    if (read(0) != 0xDD3B0001u) { printf("ddr_probe: bad IDENTITY\n"); return 1; }

    struct Case { uint32_t address; uint32_t beats; int burst; int outstanding; };
    const Case cases[] = {{0x30000000, 1, 1, 1}, {0x30000000, 64, 1, 1}, {0x00100000, 256, 4, 2},
                          {0x30000010, 1024, 16, 8}, {0x3ef00000, 4096, 64, 14}, {0x30000000, 2048, 128, 15}};
    for (const Case& c : cases) {
        write(2, c.address); write(3, c.beats); write(4, c.burst); write(5, c.outstanding);
        write(1, 1);
        int peak = 0;
        uint64_t limit = now + 1'000'000;
        while (read(1) & 1) {
            if (in_flight > peak) peak = in_flight;
            if (now > limit) { printf("  timeout\n"); failures++; break; }
        }
        uint32_t expected = 0;
        for (uint32_t b = 0; b < c.beats; b++)
            for (int lane = 0; lane < 4; lane++) expected += word_at(c.address + 16 * b + 4 * lane);
        uint32_t cycles = read(6), received = read(7), checksum = read(8), first = read(9), worst = read(10);
        bool ok = received == c.beats && checksum == expected && peak <= c.outstanding && first > 0 && worst >= first;
        printf("  %5u beats, burst %3d, outstanding %2d: %6u cycles, latency first %u max %u, peak %d in flight %s\n",
               c.beats, c.burst, c.outstanding, cycles, first, worst, peak, ok ? "ok" : "FAIL");
        failures += !ok;
    }

    printf("ddr_probe: %s\n", failures ? "FAIL" : "PASS");
    dut->final();
    return failures != 0;
}
