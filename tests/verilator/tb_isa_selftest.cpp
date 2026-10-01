// runs tpu_isa_selftest until its replay finishes and reports what the board's
// LEDs and HEX displays would show
#include <cstdio>
#include <memory>
#include "Vtpu_isa_selftest.h"
#include "verilated.h"

int main(int argc, char** argv) {
    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);
    auto dut = std::make_unique<Vtpu_isa_selftest>(ctx.get());
    dut->KEY = 0xF;
    uint64_t cyc = 0;
    const uint64_t limit = 50'000'000;
    for (; cyc < limit; cyc++) {
        dut->CLOCK_50 = 0; dut->eval();
        dut->CLOCK_50 = 1; dut->eval();
        if (!(dut->LEDR & 0x4) && cyc > 1000) break;       // LEDR2 = running
    }
    int ledr = dut->LEDR;
    bool pass = ledr & 1;
    printf("selftest: %s after %llu cycles (%.2f ms at 50 MHz), LEDR=0x%03x "
           "HEX3..0=%02x %02x %02x %02x%s%s\n",
           pass ? "PASS" : "FAIL", (unsigned long long)cyc, cyc / 50e3, ledr,
           dut->HEX3, dut->HEX2, dut->HEX1, dut->HEX0,
           (ledr & 8) ? " [timeout]" : "", (ledr & 16) ? " [core ERR]" : "");
    dut->final();
    return pass ? 0 : 1;
}
