// tpu_isa_top as a register-level transport for host/tpu/isa_device.py.
// stdin carries 'W' addr u32 (write, no reply), 'R' addr (read, 4-byte reply)
// and 'Q' (quit); on start it writes its build parameters as 5 u32 words
#include <cstdint>
#include <cstdio>
#include <memory>
#include "Vtpu_isa_top.h"
#include "verilated.h"

static std::unique_ptr<Vtpu_isa_top> dut;

static void tick() {
    dut->clk = 0;
    dut->eval();
    dut->clk = 1;
    dut->eval();
}

static bool get(void* p, size_t n) { return fread(p, 1, n, stdin) == n; }

static void put32(uint32_t v) {
    fwrite(&v, 4, 1, stdout);   // little-endian host
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = std::make_unique<Vtpu_isa_top>();
    dut->reset_n = 0;
    dut->avs_read = 0;
    dut->avs_write = 0;
    for (int i = 0; i < 4; i++) tick();
    dut->reset_n = 1;
    for (int i = 0; i < 300; i++) tick();   // past the 256-cycle power-on reset

    const uint32_t params[5] = {TB_N, TB_WMEM_ROWS, TB_UB_DEPTH, TB_ACC_DEPTH, TB_PARAM_DEPTH};
    for (uint32_t p : params) put32(p);
    fflush(stdout);

    for (;;) {
        uint8_t cmd;
        if (!get(&cmd, 1) || cmd == 'Q') break;
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
