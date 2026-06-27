# Weight Loader — Implementation Plan

The Weight Loader reads weight tiles from an on-chip ROM (initialized from a `$readmemh` file exported from PyTorch) and feeds them into the `weight_fifo` write port, handling the bottom-row-first ordering required by the staggered weight-loading contract.

---

## Role in the Datapath

```
Weight ROM (M10K, initialized via $readmemh)
       ↓  (tile address computed by FSM)
  weight_loader.sv
       ↓  (bottom-row-first, column by column)
  weight_fifo.sv (shadow bank)
       ↓  (after swap_banks pulse from FSM)
  MMU weight columns (loading_phase)
```

---

## File

`rtl/weight_loader.sv`

---

## Why a Separate Module

The `weight_fifo` accepts one element per column per cycle on its write port. The ROM has a 2-cycle M10K read latency. These constraints require a small state machine to issue read addresses, wait for data, and push results into the FIFO with correct column ordering — logic that does not belong in the FIFO or the top-level FSM.

---

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `WEIGHT_WIDTH` | 8 | Bits per weight (int8) |
| `ARRAY_ROWS` | 2 | Number of MMU rows = weights per column tile |
| `ARRAY_COLS` | 2 | Number of MMU columns |
| `ROM_ADDR_WIDTH` | 16 | Bits to address the full weight ROM (`$clog2(total_weights)`) |

---

## Port Interface

```systemverilog
module weight_loader #(
    parameter int WEIGHT_WIDTH   = 8,
    parameter int ARRAY_ROWS     = 2,
    parameter int ARRAY_COLS     = 2,
    parameter int ROM_ADDR_WIDTH = 16
) (
    input  logic clk,
    input  logic reset,

    // --- FSM control ---
    // FSM asserts start_load and provides the base address of the tile in the ROM
    input  logic                      start_load,
    input  logic [ROM_ADDR_WIDTH-1:0] tile_base_addr,   // address of weight[ARRAY_ROWS-1][0] in ROM
    output logic                      done,             // pulses 1 cycle when shadow bank fully loaded

    // --- ROM read port (M10K, 2-cycle latency) ---
    output logic [ROM_ADDR_WIDTH-1:0]     rom_addr,
    input  logic signed [WEIGHT_WIDTH-1:0] rom_data,
    // No rom_valid: address issued on cycle T, data valid on cycle T+2

    // --- weight_fifo write port ---
    output logic                           wf_write_enable_col_0,
    output logic signed [WEIGHT_WIDTH-1:0] wf_write_data_col_0,
    output logic                           wf_write_enable_col_1,
    output logic signed [WEIGHT_WIDTH-1:0] wf_write_data_col_1
);
```

---

## Weight ROM Format

The ROM is a flat 1D array of int8 values, stored in row-major order:

```
address = row * ARRAY_COLS + col
```

For a 2×2 weight matrix `W = [[w00, w01], [w10, w11]]`:
```
addr 0 → w00   (row 0, col 0)
addr 1 → w01   (row 0, col 1)
addr 2 → w10   (row 1, col 0)
addr 3 → w11   (row 1, col 1)
```

The ROM is instantiated in `tpu_top.sv` as:
```systemverilog
logic signed [WEIGHT_WIDTH-1:0] weight_rom [TOTAL_WEIGHTS];
initial $readmemh("weights.mem", weight_rom);
```

Quartus infers M10K blocks automatically for this array.

---

## Loading Order Contract

`weight_fifo` requires weights to be pushed **bottom-row first** into each column FIFO. For a 2×2 array, the correct push order is:

| Cycle | col 0 push | col 1 push | From ROM address |
|---|---|---|---|
| 0 | w10 (row 1, col 0) | w11 (row 1, col 1) | `tile_base + 2`, `tile_base + 3` |
| 1 | w00 (row 0, col 0) | w01 (row 0, col 1) | `tile_base + 0`, `tile_base + 1` |

For an N×N array, iterate rows from `ARRAY_ROWS-1` down to `0`, issuing one pair of ROM reads per row.

---

## State Machine

```
IDLE
  → on start_load: latch tile_base_addr, set row_idx = ARRAY_ROWS-1, go to ADDR_ISSUE

ADDR_ISSUE
  → issue rom_addr for col 0 and col 1 of current row_idx
  → go to WAIT_1

WAIT_1                  (first pipeline bubble for M10K 2-cycle latency)
  → go to WAIT_2

WAIT_2                  (second pipeline bubble)
  → go to PUSH

PUSH
  → rom_data is now valid; assert wf_write_enable_{col_0,col_1} with the two column values
  → if row_idx > 0: decrement row_idx, go back to ADDR_ISSUE
  → else: assert done for 1 cycle, go to IDLE
```

Total cycles per tile load (2×2): 4 states × 2 rows = ~8 cycles including latency bubbles. For N×N: `N × (2 + ARRAY_COLS)` cycles approximately.

---

## Implementation Notes

1. **Dual-column read:** The ROM is a single 1D array, so reading both columns of the same row requires two consecutive read addresses (`tile_base + row*COLS + 0` and `tile_base + row*COLS + 1`). Since M10K is single-port read, issue address for col 0 one cycle, col 1 the next cycle, and collect both results with a 2-cycle offset. This means the state machine needs to pipeline 4 cycles per row (address col 0, address col 1, wait, wait, data col 0 ready, data col 1 ready). A simpler alternative for small arrays: use a dual-port M10K (read both columns simultaneously from different port addresses).

2. **Two M10K read ports for two columns:** Quartus can infer a simple dual-port ROM if the module presents two simultaneous read addresses. This halves the per-row latency. Declare the ROM with `(* romstyle = "M10K" *)` pragma if needed.

3. **`tile_base_addr` computation:** For a tiled matrix multiplication, the FSM computes `tile_base = layer_weight_base + tile_k * ARRAY_COLS * ARRAY_ROWS + tile_col * ARRAY_COLS`. The weight_loader just treats this as an opaque base address.

4. **Shadow bank must be empty before loading:** The FSM should only pulse `start_load` when `weight_fifo`'s shadow bank is empty (i.e., the previous tile's weights have been swapped into the active bank and drained). This is guaranteed by the FSM's sequencing (LOAD_WEIGHTS state only entered when the previous WEIGHT_DRAIN has completed and banks have been swapped).

---

## Weight Export from PyTorch

After training the MNIST MLP, quantize and export weights:

```python
import torch
import numpy as np

model = ...  # trained model, load checkpoint
# Quantize to int8 (simple scale-and-round for prototype)
for name, param in model.named_parameters():
    w = param.detach().cpu().numpy()
    w_int8 = np.clip(np.round(w * 127 / w.max()), -128, 127).astype(np.int8)
    # Write in row-major order as two-hex-digit values
    with open(f"{name}.mem", "w") as f:
        for val in w_int8.flatten():
            f.write(f"{val & 0xFF:02x}\n")
```

Place the `.mem` files in the project root or a `data/` directory and reference them in `$readmemh` calls in `tpu_top.sv`.

---

## Testbench Plan

`tests/weight_loader_tb.sv` — self-checking:

1. **Basic tile load:** Initialize a small ROM with a known 2×2 weight matrix. Pulse `start_load`. Verify `done` asserts after the expected number of cycles. Verify `weight_fifo` shadow bank contains `[w10, w00]` for col 0 and `[w11, w01]` for col 1 (bottom-row first).
2. **Back-to-back loads:** Simulate two consecutive tile loads (FSM swap + reload). Verify both tiles load correctly with no corruption.
3. **`done` pulse width:** Confirm `done` is exactly 1 cycle wide.

---

## Makefile Integration

```makefile
RTL_weight_loader := $(RTL_DIR)/weight_loader.sv
DEPS_weight_loader := $(RTL_weight_loader)
DEPS_weight_loader_fifo := $(RTL_weight_loader) $(RTL_weight_fifo)
```
