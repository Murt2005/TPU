# Unified Buffer — Implementation Plan

The Unified Buffer (UB) is the on-chip activation store that connects all layers of the network. It is the last major datapath module before the top-level FSM can be built.

---

## Role in the Datapath

```
Host (ARM)          → [host_write port]  → UB bank A (input activations)
UB bank A           → [ub_read port]     → systolic_data_setup → MMU → ... → activation
activation output   → [act_write port]   → UB bank B (layer N output = layer N+1 input)
UB bank B           ↔ bank A (swap on layer boundary, controlled by FSM)
UB bank B           → [host_read port]   → Host (ARM reads final result)
```

---

## File

`rtl/unified_buffer.sv`

---

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `ROWS` | 2 | Number of activation rows (= MMU array rows) |
| `COLS` | 2 | Number of activation columns (= MMU array cols = output features) |
| `DATA_WIDTH` | 8 | Bits per element (int8 for MNIST) |
| `ADDR_WIDTH` | 4 | `$clog2(ROWS)` — row address bits |

---

## Port Interface

```systemverilog
module unified_buffer #(
    parameter int ROWS       = 2,
    parameter int COLS       = 2,
    parameter int DATA_WIDTH = 8,
    parameter int ADDR_WIDTH = $clog2(ROWS)
) (
    input  logic clk,
    input  logic reset,

    // --- Host write port (ARM writes input activation matrix row by row) ---
    input  logic [ADDR_WIDTH-1:0]       host_write_addr,
    input  logic signed [DATA_WIDTH-1:0] host_write_data [COLS],
    input  logic                         host_write_valid,

    // --- Host read port (ARM reads output matrix row by row after DONE) ---
    input  logic [ADDR_WIDTH-1:0]        host_read_addr,
    output logic signed [DATA_WIDTH-1:0] host_read_data [COLS],
    input  logic                         host_read_en,
    output logic                         host_read_valid,   // 1 cycle after host_read_en

    // --- Systolic data setup read port (FSM drives row address each cycle) ---
    input  logic [ADDR_WIDTH-1:0]        ub_read_addr,
    input  logic                         ub_read_en,
    output logic signed [DATA_WIDTH-1:0] ub_read_data [ROWS],  // one row
    output logic                         ub_read_valid,         // 1 cycle after ub_read_en

    // --- Activation write port (activation.sv pushes one row per valid cycle) ---
    input  logic signed [DATA_WIDTH-1:0] act_write_data [COLS],
    input  logic                         act_write_valid,
    // act_write_addr is a self-incrementing counter inside UB, reset by FSM
    input  logic                         act_write_addr_reset,

    // --- Bank control (FSM pulses this to swap input/output banks at layer boundary) ---
    input  logic bank_swap
);
```

---

## Internal Structure

### Memory Organization

```systemverilog
logic signed [DATA_WIDTH-1:0] mem [2][ROWS][COLS];
// mem[bank][row][col]
// bank 0 or 1; active bank = bank_sel; shadow bank = ~bank_sel
logic bank_sel;   // which bank systolic_data_setup reads from
```

### Bank Assignment

| Bank | Read by | Written by |
|---|---|---|
| `bank_sel` (active) | systolic_data_setup via `ub_read_*` | Host via `host_write_*` (before inference) |
| `~bank_sel` (shadow) | Host via `host_read_*` (after inference) | activation via `act_write_*` |

`bank_swap` flips `bank_sel`. The FSM pulses it once per layer boundary (after the activation pipeline has finished writing all rows of the current layer's output).

### Read Latency

M10K infers a **2-cycle read latency** on real hardware (registered address + registered output). The UB module must register the read address and then register the data output, emitting `ub_read_valid` 2 cycles after `ub_read_en`. The FSM must account for this when scheduling the systolic_data_setup input timing.

In simulation (Icarus with `logic` arrays), the latency will naturally match because the module adds two flip-flop stages explicitly — do not rely on combinational reads.

### Write Port for Activation Output

A self-incrementing `act_write_ptr` register inside the UB counts up on each `act_write_valid` pulse and resets on `act_write_addr_reset`. This removes the need for the FSM to track the write address separately — it only needs to pulse reset at the start of each layer.

---

## Implementation Notes

1. **No simultaneous read/write conflict:** The active bank is only read (by systolic_data_setup); the shadow bank is only written (by activation). The host write port targets the active bank *before* inference begins (when the FSM is in IDLE), and the host read port targets the shadow bank *after* inference (when the FSM is in DONE). The FSM must gate these accesses to avoid overlap.

2. **Parameterized for tiling:** For a real MNIST layer (e.g., 784 inputs), `ROWS` is the number of activation values in one tile (= array dimension N). The FSM is responsible for iterating tiles; the UB just stores one tile's worth at a time. For larger networks, `ROWS` and `COLS` can be increased to hold more data between layers.

3. **Double-ported reads:** If `ub_read_data [ROWS]` needs to deliver a full row per cycle (to match systolic_data_setup's input), the memory array must support reading all `COLS` elements of a given row in one cycle. With a `COLS`-wide array, this is naturally one M10K read per cycle (the column dimension is the word width, not a separate address dimension).

---

## Testbench Plan

`tests/unified_buffer_tb.sv` — self-checking, covering:

1. **Host write then UB read:** Write a known 2×2 matrix via `host_write_*`, then read it back row by row via `ub_read_*`. Verify data matches, including the 2-cycle latency.
2. **Activation write then host read:** Drive `act_write_*` with a known matrix. After writing, verify via `host_read_*`. Check `act_write_ptr` auto-increment.
3. **Bank swap:** After writing via activation into the shadow bank, pulse `bank_swap`. Verify the previously-shadow bank is now readable via `ub_read_*`.
4. **Reset:** Verify `act_write_addr_reset` zeroes the write pointer.

---

## Integration

Once `unified_buffer.sv` passes its unit testbench, add it to the Makefile:

```makefile
RTL_unified_buffer := $(RTL_DIR)/unified_buffer.sv
DEPS_unified_buffer := $(RTL_unified_buffer)
```

Then add an integration test `tests/ub_sds_tb.sv` that wires `unified_buffer` → `systolic_data_setup` → `mmu` and verifies activation data arrives at the MMU correctly with proper timing, including the 2-cycle UB read latency.
