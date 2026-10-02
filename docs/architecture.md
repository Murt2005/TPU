# Architecture

The hardware, top to bottom: how the core is organised, what each module does
and when, how the tiles overlap, how the memories are shared, and how the core
is wrapped for the DE1-SoC. The instruction set, register map and data
layouts are the programmer's view, in [`isa.md`](isa.md). Board setup and
build flows are in [`de1soc.md`](de1soc.md), and measured numbers in
[`performance.md`](performance.md).

## 1. The system in one picture

```
 ┌──────────── DE1-SoC ─────────────────────────────────────────────────────┐
 │  ARM (HPS, Linux)                                                         │
 │    mnist_tpu / isa_mmio  ──/dev/mem──►  lightweight HPS→FPGA bridge       │
 │                                          0xFF200000          0xFF210100   │
 │  FPGA (Cyclone V)                             │                   │       │
 │   ┌───────────── tpu_top ─────────────────────▼───┐          hex_pio      │
 │   │ host_bridge (12 registers, Avalon-MM slave)    │          → HEX0..5    │
 │   │      │ instructions, data in, results out      │                       │
 │   │ ┌────▼──────────────── tpu_core ─────────────┐ │                       │
 │   │ │ dispatch → LD │ WT │ MM │ ACT  (control)   │ │                       │
 │   │ │ WMEM → weight_fifo ─┐                      │ │                       │
 │   │ │ unified_buffer → systolic_data_setup → mmu │ │                       │
 │   │ │   → accumulator → bias → activation ─→ UB  │ │                       │
 │   │ │                                     or out │ │                       │
 │   │ └────────────────────────────────────────────┘ │                       │
 │   └────────────────────────────────────────────────┘                       │
 └───────────────────────────────────────────────────────────────────────────┘
```

The accelerator executes a program of 64-bit instructions. The host loads a
network's weights, biases and requantization words once; after that, an
inference is one short program plus the input. Hidden layers never leave the
core: each one is requantized to int8 in hardware and written back into the
unified buffer, where the next layer reads it.

`tpu_core` is board-neutral. Everything board-specific (the bridge to the
host bus, the power-on reset, pins, the self-test harness) lives in
`rtl/peripherals/` and `boards/de1soc/`.

## 2. Inside `tpu_core`

Control and datapath are separate folders. The four engines in
`rtl/control/` are state machines that sequence the TPUv1 blocks in
`rtl/datapath/`; `rtl/tpu-core.sv` wires them together, and `rtl/common/`
holds what both use (`tpu-pkg.sv`, `fifo.sv`).

```
 host FIFOs ──► dispatch ──► queues (8 deep) ──► LD ─────► WMEM, UB, bias table, quant table
   instruction 512×64                            WT ─────► WMEM reads, or DDR3 rows → weight_fifo (2 slots)
   data 1024×32                                  MM ─────► UB reads, weight rows, row tags
   out 1024×32 ◄─────────────────────────────────ACT ────► ACC reads, bias/activation control

 datapath:  unified_buffer ─► systolic_data_setup ─► mmu ◄── weight_fifo
                                                      │
                     accumulator (column de-skew, ACC memory, RMW) ─► bias ─► activation
                                                                               │
                                       unified_buffer (next layer) ◄───────────┴───► out FIFO
```

### Control (`rtl/control/`, plus `common/tpu-pkg.sv` and `tpu-core.sv`)

| File | Does |
|---|---|
| `tpu-pkg.sv` | opcodes, engine numbers, error codes, per-opcode legal-bit masks, `wait_counts_reached` (mirrors `host/tpu/isa.py`) |
| `dispatch.sv` | decodes one instruction per cycle in order: legal bits, range checks (with a shadow WBASE), routing to the engine queues, `WAIT` snapshots of the per-engine dispatch counts, the `SIGNAL` fence, `ERR`/`ERR_SEQ` |
| `load-engine.sv` | `WR_WMEM`/`WR_UB`/`WR_BIAS`/`WR_QUANT`: gathers 32-bit data words into rows (N int8) or entries (N int32) and writes them. Holds a UB entry's last word while ACT owns the UB write port |
| `weight-engine.sv` | `SET_WBASE`, and the weight half of `MATMUL`: one WMEM row read per cycle into the weight FIFO's free slot, back to back across tiles. With `wsrc = 1` it requests the `MATMUL`'s whole tile range from `weight_reader` and takes its rows from there instead, through the same one-cycle pipeline |
| `weight-reader.sv` | weights from DDR3: a 128-bit Avalon-MM burst-read master (bursts of up to 16 beats) in front of a 256-beat prefetch FIFO, unpacked into rows (`128 / 8N` per beat, so N = 4, 8 or 16). A burst issues only when the FIFO has room for it and everything in flight, since the bus can't hold read data back. Reads in flight outlive `CTRL.RESET`: only the power-on reset clears their count, and their beats are dropped |
| `matmul-engine.sv` | the compute half of `MATMUL`: the overlap schedule (§4). Issues UB row reads with the flip bit, the next tile's weight rows onto the mmu's bus, and a `{overwrite, ACC row}` tag per row |
| `activate-engine.sv` | `ACTIVATE` and `RD_UB`: reads ACC rows (when MM isn't), sequences bias → activation, writes the UB or emits words to the out FIFO |
| `tpu-core.sv` | the host FIFOs with LEVELS counts, the dispatcher and queues, WMEM and the parameter tables, the datapath wiring, completion counters, perf counters |

Every engine pops its queue only when idle. A `WAIT` at the head blocks it
until the masked engines' completion counts reach the snapshot.

### Datapath (`rtl/datapath/`, plus `common/fifo.sv`)

| File | TPUv1 block | Does | Latency |
|---|---|---|---|
| `unified-buffer.sv` | Unified Buffer | 16384 × N int8 activations; ACT's write beats LD's, MM's read beats ACT's | read 1 cycle |
| `systolic-data-setup.sv` | Systolic data setup | delays element *i* of a row by *i* cycles; carries the flip bit as a 9th bit | lane *i*: *i* cycles |
| `pe.sv` | MAC cell | `weight_current` computing, `weight_next` loading; partial sum = weight·activation + the partial sum from above | 1 cycle |
| `mmu.sv` | Matrix multiply unit | N × N PEs; a row-select weight bus per column, skewed by the column index | row *r*, column *c*: *r* + *c* + 1 |
| `weight-fifo.sv` | Weight FIFO | two tile slots (ping-pong): WT fills one while MM drains the other; a slot released this cycle refills this cycle | — |
| `accumulator.sv` | Accumulators | per-column FIFOs re-align the skewed outputs into rows; the row tag picks the ACC row; overwrite, or read-modify-write (32-bit wrap) | RMW: read at pop, write next cycle |
| `bias.sv` | (normalize) | per-column 32-bit add, wraps | combinational |
| `activation.sv` | Activation | ReLU or identity, then the requantizer's multiply and round stages (§5) | 2 registered stages |
| `fifo.sv` | — | generic show-ahead FIFO (host FIFOs, queues, column FIFOs, tags) | — |
| `block-fifo.sv` | — | show-ahead FIFO on block RAM, for `weight_reader`'s prefetch: a registered read, so an entry shows two cycles after its write | — |

### One activation row, cycle by cycle

From MM issuing a UB read at cycle *t*:
- the row reaches the skew at *t*+1, and element *r* enters PE(*r*, 0) at *t*+1+*r*;
- PE(*r*, *c*) computes at *t*+1+*r*+*c*, and the bottom row's column *c* output is valid at *t*+1+N+*c*;
- the accumulator pops the whole row once column N−1 arrives (about *t*+2N), reads the ACC row that cycle, and writes it back the next.

Rows follow one per cycle.

## 3. Memories and who uses them

| Memory | Size (board build) | Written by | Read by | Conflicts |
|---|---|---|---|---|
| WMEM | 8192 × N int8 | LD | WT | none |
| DDR3 (off chip) | the host's; 1 GB | the host, before the program | WT (`wsrc = 1`), through `weight_reader` | none in a program |
| prefetch FIFO | 256 × 128 bits | the DDR3 bus | WT | none |
| UB | 16384 × N int8 | LD, ACT | MM, ACT (`RD_UB`) | write: ACT first (LD holds its word); read: MM first (ACT waits) |
| ACC | 1024 × N int32 | accumulator | accumulator (RMW), ACT | read: MM's RMW first (ACT waits) |
| bias table | 256 × N int32 | LD | ACT, via `bias` | none |
| quant table | 256 × N int32 | LD | ACT, via `activation` | none (same address as bias) |

All reads are registered, so every memory infers block RAM: 2.7 Mbit of the
Cyclone V's 4 Mbit. Ordering between engines (LD before MM, MM before ACT,
ACT's UB writes before the next `MATMUL`) is the program's job, expressed with
`WAIT` ([`isa.md`](isa.md) §2). The priorities only resolve same-cycle port
use.

## 4. Overlapped tiles

The first core loaded, computed and drained each tile serially, so its array
was fed 9–16% of the time ([`utilization.md`](utilization.md)). This core
loads tile *j*+1's weights while tile *j* computes:

- **PE.** Two weights. The first activation row of every tile carries a flip
  bit through the skew and across the array. At each PE it computes with
  `weight_next` and promotes it to `weight_current`, on exactly the cycle that tile's data
  arrives there.
- **Weight bus.** One row-select bus per column, delayed *c* cycles at column
  *c*. A weight row then reaches every column the same distance ahead of the
  flip that will use it.
- **Schedule** (`matmul_engine`). A window of max(m, N) cycles per tile. It
  streams tile *j*'s m activation rows from position 0, and in the window's
  last N cycles writes tile *j*+1's N weight rows into `weight_next`. The first
  tile has a preload window of N cycles, and the last has no weights.
- **Stalls.** If the next tile isn't in the weight FIFO, the whole window
  freezes (counted in `PERF_MM_WSTALL`). A freeze only widens the gaps the
  PEs rely on, so it never breaks timing.
- **Weight FIFO.** Two slots, refilled the cycle MM releases one. Without
  that same-cycle refill, windows of N cycles stalled about half a cycle per
  tile.
- **Accumulator.** The same ACC row comes round at most once per window
  (≥ N ≥ 2 cycles), so a read-modify-write always lands before the next read
  of that row.

Measured, in Verilator and on the board: each extra tile costs exactly
max(m, N) cycles, with no steady-state stalls, so at m ≥ N the array is fed
every cycle.

`pe.sv` carries simulation-only checks (`ifndef SYNTHESIS`, `$fatal`): no
weight is overwritten before its flip, and there is no flip without a pending
weight.

## 5. The requantizer

`ACTIVATE` with `rq = 1` turns a 32-bit sum into int8 with a per-column word
`{shift[29:24], M0[23:0]}`:

```
v27 = saturate v to 27 bits       p = v27 × M0 (27×25, one DSP per lane)
r   = (p + 2^(shift−1)) >>> shift (no rounding term when shift = 0)
out = clamp r to [−128, 127]
```

ACT spends three states on it: latch the biased, ReLU'd row; multiply
(`activation.sv`'s product register); round and clamp. A single-cycle
version missed 50 MHz by 4 ns. The 8 lanes use 8 of the 78 DSP blocks. The
host's choice of `M0` and `shift`, and how it compares to numpy rounding, are
in [`isa.md`](isa.md) §5.

## 6. Parameters

| Parameter | Board builds | Notes |
|---|---|---|
| `ARRAY_SIZE` | 8 | N, the array size; a multiple of 4 (int8 rows pack into 32-bit words). Verified in simulation at 8 and 4 |
| `WMEM_ROWS`, `UB_DEPTH`, `ACC_DEPTH`, `PARAMETER_DEPTH` | 8192, 16384, 1024, 256 | address widths follow; the instruction fields cap them (16-, 14-, 10- and 8-bit addresses) |
| `INSTRUCTION_FIFO_DEPTH`, `DATA_FIFO_DEPTH`, `OUTPUT_FIFO_DEPTH`, `QUEUE_DEPTH` | 512, 1024, 1024, 8 | `LEVELS` reports free space and the out count |

At N = 8 the Cyclone V build uses 78 of 87 DSP blocks: 64 PE multipliers, 8
requantizer lanes, and the tile-count products. A 16×16 array needs DSP
packing ([`backlog.md`](backlog.md)).

## 7. The board wrapper

| File | Does |
|---|---|
| `rtl/peripherals/host-bridge.sv` | the 12-register Avalon-MM slave ([`isa.md`](isa.md) §4): fixed read latency 1, `waitrequest` only on writes into a full FIFO, single clock domain |
| `boards/de1soc/top/tpu-top.sv` | `host_bridge` + `tpu_core` + a 256-cycle power-on reset, so the core doesn't depend on `reset_n` pulsing; exports the core's DDR3 master (`avm_*`) |
| `boards/de1soc/top/tpu-selftest.sv`, `replay.sv` | the FPGA-only self-test: a ROM-fed Avalon master replays a register transcript into `tpu_top` and reports on LEDs/HEX |
| `boards/de1soc/top/hex-display.sv` | the HEX decoder behind the GHRD's `hex_pio` (5-bit code per digit) |
| `boards/de1soc/fpga/hps/tpu_hw.tcl` | `tpu_top` as a Platform Designer component: its slave on the HPS lightweight bridge, its master on the 128-bit FPGA-to-SDRAM port |

## 8. The software around it

| Where | What |
|---|---|
| `host/tpu/isa.py` | the encoder and decoder, from one field table |
| `host/tpu/isa_model.py` | the reference model: executes a program in order with the exact arithmetic |
| `host/tpu/isa_layout.py`, `isa_compile.py` | data layouts; an int8 MLP → load and infer programs |
| `host/tpu/isa_waits.py` | per-engine read/write sets; finds unordered hazards, inserts the minimal `WAIT`s |
| `host/tpu/isa_device.py` | `IsaDevice` over three links: Verilator (`IsaSimLink`), the board's console (`IsaSerialLink` + `BoardConsole`), and, on the ARM in C, `/dev/mem` |
| `host/tpu/golden.py` | reference numerics shared by the model and the tests |
| `boards/de1soc/sw/` | ARM programs: `isa_mmio` (register server), `setbaud` |
| `software/mnist/` | the demo model, its host reference, the drawing demo, and `de1soc/mnist_tpu` (MNIST end to end on the ARM) |

## 9. Build flow

- **Simulation:** Verilator. `make test` runs the UVM block tests, `make
  sim-test` runs the RTL against the model at N = 8 and 4, and `make
  selftest-sim` replays the self-test ROM. See [`verification.md`](verification.md).
- **FPGA:** Quartus Prime Lite in an x86 VM.
  - `boards/de1soc/fpga/selftest/` builds the self-test, loaded over JTAG.
  - `boards/de1soc/fpga/hps/` extracts Terasic's GHRD, adds the TPU and
    `hex_pio` with `qsys-script`, and builds the `.rbf` U-Boot loads from the
    SD card. See [`de1soc.md`](de1soc.md).

## 10. History

This is the repo's second core. The first, a byte-protocol design with a
single serial sequencer, ran on a pico2-ice (iCE40UP5K) and is preserved at
the git tag `pico2-ice-final`. Its measured limits motivated this design:
- the array was idle 84–93% of the time;
- weights were re-sent every tile;
- layers returned to the host for requantization.

The new core reuses that core's datapath files (`pe`, `mmu`,
`weight_fifo`, `accumulator`, `bias`, `activation`, `unified_buffer`,
`systolic_data_setup`, `fifo`), rewritten for the new ISA.
[`performance.md`](performance.md) and [`utilization.md`](utilization.md)
keep its numbers.
