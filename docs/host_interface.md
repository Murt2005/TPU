# Host Interface — Implementation Plan

The Host Interface is the AXI4-Lite slave that bridges the Lightweight HPS-to-FPGA (LWH2F) bridge to the internal TPU modules. ARM software running on the Cortex-A9 accesses it as memory-mapped registers via `/dev/mem`.

---

## Role in the System

```
ARM Cortex-A9 (HPS)
  │  mmap(0xFF200000)  /dev/mem
  ▼
LWH2F AXI4-Lite fabric  (inside Cyclone V)
  ▼
host_interface.sv  (AXI4-Lite slave + CSR decoder)
  ├──▶  unified_buffer.host_write_*    (load input activation matrix)
  ├──▶  unified_buffer.host_read_*     (read output result matrix)
  ├──▶  weight_fifo.write_enable_*     (load weights into shadow bank)
  ├──▶  tpu_top FSM: start / reset     (control signals)
  └──▶  tpu_top FSM: status read       (BUSY, DONE, ERROR)
```

---

## File

`rtl/host_interface.sv`

---

## V1 Strategy: LWH2F Only

The LWH2F bridge gives the ARM a 2 MB, 32-bit AXI4-Lite window starting at `0xFF20_0000`. In v1, the host_interface exposes a flat register file at this base. No kernel driver is required — the ARM program uses `mmap("/dev/mem", ...)` and plain `volatile uint32_t *` pointer accesses.

**Bridge initialization (ARM side, one-time setup):**
```c
int fd = open("/dev/mem", O_RDWR | O_SYNC);
// Release bridge reset (brgmodrst at 0xFFD0501C, bit 1 = LWH2F)
volatile uint32_t *sysm = mmap(NULL, 0x1000, PROT_RW, MAP_SHARED, fd, 0xFFD05000);
sysm[7] &= ~0x2;   // clear LWH2F reset bit

// Map the FPGA CSR window
volatile uint32_t *fpga = mmap(NULL, 0x200000, PROT_RW, MAP_SHARED, fd, 0xFF200000);
```

---

## CSR Register Map

All registers are 32-bit, word-aligned. Base address: `0xFF20_0000` (ARM view).

| Offset | Register | R/W | Bit fields |
|---|---|---|---|
| `0x00` | `CTRL` | W | [0] START — pulse to begin inference; [1] RESET — synchronous reset of TPU |
| `0x04` | `STATUS` | R | [0] BUSY — inference in progress; [1] DONE — result ready; [2] ERROR — pipeline fault |
| `0x08` | `DATA_IN` | W | [15:8] element for col 1, [7:0] element for col 0 (two int8s packed per write) |
| `0x0C` | `DATA_OUT` | R | [15:8] element for col 1, [7:0] element for col 0 (two int8s packed per read) |
| `0x10` | `ADDR` | W | [15:8] column address, [7:0] row address — set before DATA_IN write or DATA_OUT read |
| `0x14` | `WEIGHT_DATA` | W | [15:8] weight for col 1, [7:0] weight for col 0 (two int8s packed) |
| `0x18` | `WEIGHT_ADDR` | W | [15:8] weight column, [7:0] weight row — set before WEIGHT_DATA write |
| `0x1C` | `LAYER_CFG` | W | [7:0] num_input_rows, [15:8] num_output_cols, [23:16] num_layers |

---

## AXI4-Lite Slave Implementation

AXI4-Lite is the simplest AXI variant: no bursts, no out-of-order transactions, 32-bit data, one transaction at a time. The slave needs five channels:

| Channel | Signals | Direction |
|---|---|---|
| Write address | `awaddr`, `awvalid`, `awready` | Master→Slave, Slave→Master |
| Write data | `wdata`, `wstrb`, `wvalid`, `wready` | Master→Slave |
| Write response | `bresp`, `bvalid`, `bready` | Slave→Master |
| Read address | `araddr`, `arvalid`, `arready` | Master→Slave |
| Read data | `rdata`, `rresp`, `rvalid`, `rready` | Slave→Master |

**Minimal implementation pattern:**
- Accept write address and write data independently (they can arrive in either order per AXI spec)
- Latch both; once both have arrived, decode the address, write the register, assert `bvalid` with `bresp=OKAY`
- On read: accept address, look up the register combinationally, assert `rvalid` with data and `rresp=OKAY`
- For CSRs with no backpressure: `awready`, `wready`, `arready` can be tied high (always ready)

```systemverilog
// Minimal AXI4-Lite write path (simplified):
always_ff @(posedge clk) begin
    if (awvalid && wvalid) begin  // both channels arrived (or latch each independently)
        case (awaddr[4:2])        // word-aligned offset → register index
            3'd0: ctrl_reg  <= wdata;
            3'd2: data_in   <= wdata;  // triggers host_write_valid to UB
            3'd4: addr_reg  <= wdata;
            3'd5: weight_data <= wdata; // triggers wf_write_enable
            3'd6: weight_addr <= wdata;
            3'd7: layer_cfg <= wdata;
        endcase
        bvalid <= 1'b1;
    end
    if (bready && bvalid) bvalid <= 1'b0;
end
```

If using **Quartus Platform Designer (Qsys):** add an Avalon-MM or AXI4-Lite slave component, connect to the LWH2F master port, and let Qsys generate the interconnect. The host_interface module becomes an Avalon-MM slave with `address`, `read`, `write`, `readdata`, `writedata` ports — simpler to implement than raw AXI.

---

## ARM Software Example (inference flow)

```c
// Assume fpga pointer is already mapped and bridges released

// 1. Load weights (done once per network)
for (int r = ARRAY_ROWS-1; r >= 0; r--) {
    for (int c = 0; c < ARRAY_COLS; c += 2) {
        fpga[WEIGHT_ADDR/4] = (c << 8) | r;
        fpga[WEIGHT_DATA/4] = (W[r][c+1] & 0xFF) << 8 | (W[r][c] & 0xFF);
    }
}

// 2. Load input activation matrix
for (int r = 0; r < NUM_ROWS; r++) {
    fpga[ADDR/4]     = r;
    fpga[DATA_IN/4]  = (act[r][1] & 0xFF) << 8 | (act[r][0] & 0xFF);
}

// 3. Start inference
fpga[CTRL/4] = 0x1;  // START

// 4. Poll done
while (!(fpga[STATUS/4] & 0x2));  // wait for DONE bit

// 5. Read result
for (int c = 0; c < OUTPUT_COLS; c += 2) {
    fpga[ADDR/4] = c >> 1;
    uint32_t result = fpga[DATA_OUT/4];
    output[c]   = (int8_t)(result & 0xFF);
    output[c+1] = (int8_t)((result >> 8) & 0xFF);
}
```

---

## Implementation Notes

1. **START is edge-triggered:** The FSM monitors a rising edge on the START bit (not the level) so that the ARM holding the bit high after writing does not re-trigger inference.

2. **RESET behavior:** Asserting the RESET bit drives the synchronous `reset` signal into all TPU modules. The ARM must deassert it before asserting START.

3. **Byte-enable strobe (`wstrb`):** For full AXI compliance, respect `wstrb` when writing (only update bytes whose strobe bit is set). For a CSR-only interface, this can be simplified to always-write-all-bytes.

4. **WEIGHT_DATA routing:** Writing to WEIGHT_DATA causes the host_interface to assert `weight_fifo.write_enable_col_0` and `write_enable_col_1` for one cycle, pushing the two packed int8 values into the shadow bank FIFOs. The WEIGHT_ADDR register provides the row/column index for documentation but the weight_fifo pushes weights in the order they arrive — the ARM must write them bottom-row-first per the weight_fifo contract.

5. **Future extension:** In v2, replace the per-element register-write loop with a DMA descriptor written to the H2F bridge. The host_interface grows a DMA command register that kicks off a burst transfer from HPS DDR3 to the UB or weight_fifo without involving the ARM CPU in the data path.

---

## Testbench Plan

`tests/host_interface_tb.sv` — self-checking:

1. **Register write/read:** Write known values to DATA_IN / WEIGHT_DATA; verify they appear on the UB and weight_fifo write ports.
2. **AXI handshake:** Drive AWVALID and WVALID with small delays between them; confirm BVALID asserts correctly.
3. **STATUS readback:** Force FSM signals (BUSY, DONE) via DUT backdoor; confirm STATUS register reflects them.
4. **START edge detection:** Assert START, deassert; confirm only one start pulse reaches the FSM.
5. **RESET propagation:** Assert RESET bit; confirm the `reset` output to the TPU modules goes high.

---

## Makefile Integration

```makefile
RTL_host_interface := $(RTL_DIR)/host_interface.sv
DEPS_host_interface := $(RTL_host_interface)
```
