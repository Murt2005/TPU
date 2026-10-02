# The instruction set

The programmer's view of the core: the 64-bit instructions, the four engines
that execute them concurrently, `WAIT`/`SIGNAL`, decode errors, how data is
laid out in the on-chip memories, the host register interface, the
requantizer's arithmetic, and how a network compiles. Weights, activations,
layer outputs and requantization parameters stay on chip between
instructions, so a whole multi-layer network runs on the core: only the input
goes in and only the final scores come out. The hardware that implements it
is in [`architecture.md`](architecture.md).

| | |
|---|---|
| RTL | `rtl/` (`common/tpu-pkg.sv` holds the constants; `peripherals/host-bridge.sv` is the register interface) |
| Top levels | `boards/de1soc/top/tpu-top.sv` (bridge + core); in the board designs, `tpu-selftest.sv` and the GHRD component |
| Reference model | `host/tpu/isa_model.py`: executes a program in order with the exact arithmetic; the RTL must match it word for word |
| Design spec | the instruction-stream spec doc (claude.ai artifact `FP1ach14aGXhH2N1aCLCox`). This page describes what is built |
| Status | Spec phases 1–3 built: the serial core, then the requantizer and on-core layer chaining, then overlapped tiles. **Hardware-validated on the DE1-SoC** ([`de1soc.md`](de1soc.md)). Phase 5 (DDR3) begun: FPGA-to-SDRAM bandwidth measured on the board (800 MB/s), `MATMUL wsrc=1` in the reference model; the RTL still rejects it |

## 1. Shape

```
 host ── Avalon-MM ──► host_bridge
                         ├─► instruction FIFO (512 × 64) ──► dispatcher ──► LD │ WT │ MM │ ACT queues (8 deep)
                         ├─► data FIFO (1024 × 32) ──► LD ──► WMEM, UB, bias table, quant table
                         └─◄ out FIFO  (1024 × 32) ◄──────────────────────────────────────────── ACT

 WT : WMEM (8192 × N int8) ──► 2-slot tile buffer ──► MM
 MM : UB rows (16384 × N int8) + tile ──► N × N array ──► ACC (1024 × N int32, read-modify-write)
 ACT: ACC + bias ──► ReLU ──► requantize ──► UB (the next layer's input) or the out FIFO
```

`N` is the array size (`N = 8` in every board build, so 64 PEs). The memory
depths are parameters of `tpu_core` (`WMEM_ROWS`, `UB_DEPTH`, `ACC_DEPTH`,
`PARAMETER_DEPTH`). The figures above are the defaults the board builds use.

### The four engines

| Engine | Executes | Reads | Writes |
|---|---|---|---|
| **LD** | `WR_WMEM`, `WR_UB`, `WR_BIAS`, `WR_QUANT` | data FIFO | WMEM, UB, bias table, quant table |
| **WT** | `SET_WBASE`, the weight half of `MATMUL` | WMEM | the 2-slot tile buffer |
| **MM** | the compute half of `MATMUL` | tile buffer, UB | ACC (read-modify-write) |
| **ACT** | `ACTIVATE`, `RD_UB` | ACC, bias and quant tables, UB | UB, out FIFO |

The dispatcher decodes in order and pushes each instruction to its engine's
queue. A `MATMUL` goes to both WT and MM. Engines run independently and
concurrently. **The only interlock in hardware is WT → MM through the tile
buffer**: MM waits until the tile it needs is there. Every other ordering
(LD before MM, MM before ACT, ACT's UB writes before the next layer's
`MATMUL`) is the program's job, expressed with `WAIT`.

## 2. Instructions

Opcode in bits `[63:58]`. Counts are stored minus one, and the host encoder
takes them naturally. One field table in `host/tpu/isa.py` drives the
encoder, the decoder and the reserved-bit check, so they can't disagree. Any
bit outside an opcode's fields must be zero.

| Op | Mnemonic | Fields (bit ranges) | Engine |
|---|---|---|---|
| `0x00` | `NOP` | — | none |
| `0x01` | `WR_WMEM` | `wmem_row` 47:32, `n_rows` 15:0 | LD |
| `0x02` | `WR_UB` | `ub_addr` 45:32, `n` 11:0 | LD |
| `0x03` | `WR_BIAS` | `param_idx` 39:32, `n` 7:0 | LD |
| `0x04` | `WR_QUANT` | `param_idx` 39:32, `n` 7:0 | LD |
| `0x05` | `RD_DDR_UB` | `ub_addr` 57:44, `n` 43:32, `ddr_addr` 31:0 | *phase 5: `ERR_UNIMPL`* |
| `0x06` | `SET_WBASE` | `wbase` 31:0 (a tile index) | WT |
| `0x07` | `SET_OBASE` | `obase` 31:0 | *phase 5: `ERR_UNIMPL`* |
| `0x10` | `MATMUL` | `acc` 57, `wsrc` 56, `m` 55:48, `k_tiles` 47:36, `n_blocks` 35:26, `acc_addr` 25:16, `ub_addr` 15:2 | WT + MM |
| `0x18` | `ACTIVATE` | `func` 57:56, `rq` 55, `dst` 54:53, `bias` 52, `n_blocks` 51:42, `m` 41:34, `acc_addr` 33:24, `ub_addr` 23:10, `param_idx` 9:2 | ACT |
| `0x19` | `RD_UB` | `ub_addr` 45:32, `n` 11:0 | ACT |
| `0x20` | `WAIT` | `target` 57:56, `mask` 51:48 | the target's queue |
| `0x21` | `SIGNAL` | `tag` 15:0 | dispatcher |

**`MATMUL m, k_tiles, n_blocks`** computes `ACC[n_blocks·m rows] (+)= A[m × k_tiles·N] @ W[k_tiles·N × n_blocks·N]`.
Weights are read starting at tile `WBASE`, and WBASE then advances by
`n_blocks · k_tiles`, so consecutive `MATMUL`s walk WMEM without a
`SET_WBASE` in between. `acc = 1` adds to ACC instead of overwriting, which
is how a K-sum splits across several `MATMUL`s.

`wsrc = 1` streams the weights from DDR3 instead of WMEM (phase 5; in the
reference model, not yet in the RTL). WBASE stays a tile index: tile *t* is
the `N·N` bytes at DDR3 byte address `t·N·N` (64 B at `N = 8`, four 16-byte
beats), rows in WMEM's order. There is one WBASE for both sources, and every
`MATMUL` advances it, whichever source it reads. The range check is against
the DDR3 size (1 GB) instead of WMEM. The host writes the weights into DDR3
itself, outside the program (the ARM's stores; a preload in simulation), so
nothing in a program orders them: they must be in place, and visible past the
ARM's caches, before the program that reads them starts.

**`ACTIVATE`** reads `n_blocks · m` ACC rows and computes
`v = acc + bias[param_idx + block]` (32-bit wrap, if `bias = 1`), then
applies `func`: 0 = identity, 1 = ReLU, 2–3 reserved. With `rq = 1` it
requantizes to int8 (§5). `dst = 0` writes one UB entry per row, which
requires `rq = 1`. `dst = 1` sends to the host: `N` int32 words per row, or
`N/4` packed int8 words with `rq`. `dst = 2` is DDR3 (phase 5).

**`RD_UB`** sends `n` UB entries to the host, `N/4` words each.

### `WAIT` and `SIGNAL`

The dispatcher counts instructions dispatched to each engine. A `WAIT
target, mask` goes into `target`'s queue carrying a snapshot of those counts
for the engines in `mask`. When it reaches the head of the queue, it blocks
that engine until each masked engine's completed count has caught up with
the snapshot (16-bit counters, modulo compare). So `WAIT MM on LD` means: MM
must not start anything else until LD has finished everything that was
dispatched before this `WAIT`.

`SIGNAL tag` is a fence. The dispatcher stops issuing until every engine
has completed everything dispatched, then sets `STATUS.DONE` and
`STATUS.TAG = tag`. A program ends with a `SIGNAL`. The host waits for
`DONE`, then reads the out FIFO.

`host/tpu/isa_waits.py` knows what every instruction reads and writes per
engine (WMEM/UB/ACC/param ranges, with `MATMUL` split into its WT and MM
parts). `check_waits()` lists every cross-engine hazard that no `WAIT`
orders, and `insert_waits()` adds the minimal `WAIT`s. The compiled MNIST
program's `WAIT`s are exactly the necessary ones.

### Decode errors

Checked in this order. The first failing check halts the dispatcher and sets
`STATUS.ERR`, `STATUS.ERR_CODE`, and `ERR_SEQ` (the instruction's index
since reset). `CTRL.RESET` clears it.

| Code | Name | Raised for |
|---|---|---|
| 1 | `OPCODE` | unknown opcode |
| 2 | `RESERVED` | a set bit outside the opcode's fields; `ACTIVATE` `func` 2–3 or `dst` 3 |
| 5 | `UNIMPL` | `RD_DDR_UB`, `SET_OBASE`, `MATMUL wsrc=1`, `ACTIVATE dst=DDR` |
| 4 | `COMBO` | `ACTIVATE dst=UB` with `rq=0` (int32 can't go into an int8 UB entry) |
| 3 | `RANGE` | any memory range past the end: WMEM rows, UB entries, params, ACC rows, or `(WBASE + n_blocks·k_tiles)·N` past WMEM |

## 3. Data layouts

The host lays data out once (`host/tpu/isa_layout.py`). Every stride is fixed
by the instruction fields:

| Memory | Unit | Layout |
|---|---|---|
| WMEM | one row = `N` int8 | Tiles are `N` rows of `N`. Tile index = `WBASE + n·k_tiles + k` for output block `n` and K-chunk `k`, i.e. block-major, then K. Within a tile, row `r` is K index `r` (top row first), and byte `c` is output column `c` |
| UB | one entry = `N` int8 | **K-chunk-major**: chunk `k` of activation row `i` sits at `ub_addr + k·m + i`. One layer's `ACTIVATE` into the UB therefore lands exactly where the next layer's `MATMUL` reads, when that layer's `k_tiles` equals this one's `n_blocks` |
| ACC | one row = `N` int32 | block-major: `acc_addr + n·m + i` |
| bias / quant | one entry = `N` int32 | one entry per output block: `param_idx + n` |

Data words are 32-bit. int8 groups pack 4 per word, little-endian, and each
row is padded to whole words.

## 4. Host interface (`host_bridge`)

An Avalon-MM slave with 12 word registers, a fixed read latency of 1, and
`waitrequest` only on writes into a full FIFO. On the DE1-SoC it sits at
`0xFF200000` (HPS lightweight bridge), so register `r` is at
`0xFF200000 + 4r`.

| # | Name | Access | Meaning |
|---|---|---|---|
| 0 | `INSN_LO` | W | low half of the next instruction (latched) |
| 1 | `INSN_HI` | W | high half; pushes `{HI, LO}` to the instruction FIFO |
| 2 | `DATA` | W | pushes a data word |
| 3 | `OUT` | R | pops an out word. Empty reads return 0 and set `UNDERFLOW` |
| 4 | `STATUS` | R | `{TAG[31:16], ERR_CODE[15:8], 0, UNDERFLOW[3], IDLE[2], ERR[1], DONE[0]}` |
| 5 | `LEVELS` | R | `{output_count[31:21], data_free[20:10], instruction_free[9:0]}` |
| 6 | `CTRL` | W | bit 0 `RESET`: flush queues and FIFOs, clear ERR; memories keep their contents. Bit 1 `CLEAR_DONE` (and `UNDERFLOW`). Bit 2 `CLEAR_PERF` |
| 7 | `ERR_SEQ` | R | index of the faulting instruction |
| 8 | `PERF_CYCLES` | R | free-running cycles since `CLEAR_PERF` |
| 9 | `PERF_MM_BEATS` | R | activation rows MM has issued |
| 10 | `PERF_MM_WSTALL` | R | cycles MM waited for a weight tile |
| 11 | `PERF_MM_SYNC` | R | cycles an MM `WAIT` blocked |

A run: write `CTRL.CLEAR_DONE`, push the instructions, push the data words in
the order the LD instructions consume them, poll `STATUS` until `DONE` (or
`ERR`), then read `OUT`. `host/tpu/isa_device.py`'s `IsaDevice.run()` does
exactly this. The links behind it:

| Link | Reaches | Use |
|---|---|---|
| `IsaSimLink` | `tb_isa`, a Verilator build of `tpu_top` (`make rtl-sim`) | `make sim-test` |
| `IsaSerialLink` | the board: runs `isa_mmio` (an ARM `/dev/mem` register server) over the HPS console | `test_isa_rtl.py serial:<port>` |
| (C, on the ARM) | `/dev/mem` directly | `software/mnist/de1soc/mnist_tpu` |

## 5. Requantizer

`ACTIVATE rq = 1` maps each 32-bit value to int8 with a per-column quant word
`{shift[29:24], M0[23:0]}`:

```
v27 = saturate v to 27 bits            [-2^26, 2^26 - 1]
p   = v27 * M0                          (27 x 25 bits: one DSP per lane)
r   = shift == 0 ? p : (p + 2^(shift-1)) >>> shift     (round half up)
out = clamp r to int8
```

The host picks `M0` and `shift` for a real scale `M` (`isa.quant_params`):
`shift = 23 - floor(log2 M)`, `M0 = round(M · 2^shift)`, renormalizing if
`M0` reaches `2^24`. It requires `M >= 2^-19`, which keeps the 27-bit
saturation exact.

Against the host's `np.round(v / scale)` (round half to even), the only
difference over the whole int16 range at MNIST's hidden scale is the tie at
`v = 10,450`. It never comes up on the 10,000-image test set.

In hardware the requantizer is three ACT states (bias+ReLU, multiply, round),
since a single-cycle version missed 50 MHz by 4 ns.

## 6. Overlapped tiles

`MATMUL` runs one tile per max(m, N) cycles: while tile *j*'s m rows stream
through the array, tile *j*+1's weights load into the PEs' second weight
register, and the next tile's first row swaps them in. A program sees this
only as throughput. The schedule and the PE are described in
[`architecture.md`](architecture.md) §4.

## 7. Compiling a network

`host/tpu/isa_compile.py`'s `compile_mlp(layers, m)` turns an int8 MLP into
two programs:

- **load**: `WR_WMEM`, `WR_BIAS` and `WR_QUANT` for every layer, run once.
- **infer**: per batch of `m` inputs, `WR_UB` → `MATMUL` → `WAIT ACT on MM` →
  `ACTIVATE` to the UB (with `rq`) → `WAIT MM on ACT` → next layer … →
  last `ACTIVATE` to the host → `SIGNAL`.

The hidden layers never leave the core. For MNIST (144 → 64 → 10, `N = 8`)
the infer program is 11 instructions plus 18·m·2 data words in, and 2·m·8
words out. See [`mnist.md`](mnist.md) §8 for the board numbers.

## 8. Verification

| What | How | Result |
|---|---|---|
| Model vs independent references | `make model-test`: random layers vs `tpu.golden`, MNIST layer 1 vs `hw_layer`, requant vs host rounding, `isa_waits` on the compiled program | pass |
| RTL vs model, word for word | `make sim-test`: every decode error, 40 random layers (incl. split K), MNIST, requantizer (every int16 + edges + random int32, three tables), 40 random concurrent programs with inserted `WAIT`s (most diverge without them), cycle-exact tile rate, at N = 8 and N = 4 | pass |
| Netlist, no host | `boards/de1soc/fpga/selftest`: the tests as a ROM transcript replayed into the bridge on the FPGA, plus on-chip tile-rate checks | **PASS on the board** |
| Netlist, from the ARM | `test_isa_rtl.py serial:<port>`: the whole suite over the console | **all functional tests pass on the board** |
| Whole application | `mnist_tpu bench`: 10,000 MNIST images | **10,000/10,000 equal to the model on the board** |

Details in [`verification.md`](verification.md).
