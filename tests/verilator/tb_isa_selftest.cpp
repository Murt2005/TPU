// runs tpu_isa_selftest until its replay finishes, reports what the board's
// LEDs and HEX displays would show, then reads every capture slot back through
// SW9 + SW4..0 and the six HEX digits, exactly as a person at the board would
#include <cstdio>
#include <cstdlib>
#include <memory>
#include "Vtpu_isa_selftest.h"
#include "verilated.h"

static int unseg(int s) {
    static const int seg[16] = {0x40, 0x79, 0x24, 0x30, 0x19, 0x12, 0x02, 0x78,
                                0x00, 0x10, 0x08, 0x03, 0x46, 0x21, 0x06, 0x0e};
    for (int v = 0; v < 16; v++)
        if (seg[v] == s) return v;
    return -1;
}

int main(int argc, char** argv) {
    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);
    auto dut = std::make_unique<Vtpu_isa_selftest>(ctx.get());
    auto tick = [&] { dut->CLOCK_50 = 0; dut->eval(); dut->CLOCK_50 = 1; dut->eval(); };
    dut->KEY = 0xF;
    dut->SW = 0;
    uint64_t cyc = 0;
    const uint64_t limit = 50'000'000;
    for (; cyc < limit; cyc++) {
        tick();
        if (!(dut->LEDR & 0x4) && cyc > 1000) break;       // LEDR2 = running
    }
    int ledr = dut->LEDR;
    bool pass = ledr & 1;
    printf("selftest: %s after %llu cycles (%.2f ms at 50 MHz), LEDR=0x%03x "
           "HEX3..0=%02x %02x %02x %02x%s%s\n",
           pass ? "PASS" : "FAIL", (unsigned long long)cyc, cyc / 50e3, ledr,
           dut->HEX3, dut->HEX2, dut->HEX1, dut->HEX0,
           (ledr & 8) ? " [timeout]" : "", (ledr & 16) ? " [core ERR]" : "");
    int slots = argc > 1 ? atoi(argv[argc - 1]) : 0;
    for (int i = 0; i < slots; i++) {
        dut->SW = 0x200 | i;
        tick(); tick();
        int d[6] = {unseg(dut->HEX5), unseg(dut->HEX4), unseg(dut->HEX3),
                    unseg(dut->HEX2), unseg(dut->HEX1), unseg(dut->HEX0)};
        long v = 0;
        for (int k = 0; k < 6; k++) v = v * 16 + (d[k] < 0 ? 0 : d[k]);
        printf("  slot %2d: HEX %x%x%x%x%x%x = %ld\n", i, d[0], d[1], d[2], d[3], d[4], d[5], v);
    }
    dut->final();
    return pass ? 0 : 1;
}
