# docs/

Design and reference documentation for this repo's from-scratch TPUv1
reimplementation. The root [`README.md`](../README.md) is the entry point —
it owns the quick start, the toolchain install, and the troubleshooting
table. These files are the layer beneath it: the *why* and the measured
detail, not the getting-started path.

## Two cores, two boards

| Core | Board | Status | Start at |
|---|---|---|---|
| **Instruction-stream core** (`rtl/isa/`): 64-bit instructions, four concurrent engines, layers chained on chip, overlapped tiles | **DE1-SoC** (Cyclone V + ARM) | hardware-validated; **the active target** | [`isa.md`](isa.md), [`de1soc.md`](de1soc.md) |
| Legacy byte-protocol core (`rtl/core/`): `[CMD][LEN][payload]` frames, one serial sequencer | pico2-ice (iCE40UP5K + RP2350) | hardware-validated; no longer developed | [`architecture.md`](architecture.md), [`pico2-ice.md`](pico2-ice.md) |

## Reading order

New to the repo, want to run it on a board:
1. Root [`README.md`](../README.md) §1 — the DE1-SoC quick start.
2. [`de1soc.md`](de1soc.md) — the board, the toolchain, both build flows, and the gotchas.

New to the repo, want to understand the design:
1. [`isa.md`](isa.md) — the current core: instructions, engines, layouts, requantizer, overlap.
2. [`architecture.md`](architecture.md) — the legacy core, and the TPUv1 datapath both share.
3. [`performance.md`](performance.md) — measured numbers on both boards.
4. [`utilization.md`](utilization.md) — why the legacy core's array idled, which is what the new core fixes.

Working on the code:
- [`repo-map.md`](repo-map.md) — file-by-file.
- [`verification.md`](verification.md) — what to run before trusting a change.
- [`backlog.md`](backlog.md) — what's still open.

## Index

| File | What's in it |
|---|---|
| [`isa.md`](isa.md) | The instruction-stream core: the 64-bit ISA and its fields, the LD/WT/MM/ACT engines, `WAIT`/`SIGNAL`, decode errors, memory layouts, the `isa_bridge` register map, the requantizer, the overlapped-tile scheme, the MLP compiler |
| [`de1soc.md`](de1soc.md) | DE1-SoC target: what runs on the board and what was measured, the rev H board and its two serial ports, the Quartus-in-OrbStack toolchain, the self-test and GHRD flows, the ARM-side programs, and the gotchas |
| [`architecture.md`](architecture.md) | The legacy core: the four host paths, the datapath module by module, the sequencer FSM, the parameter model (`ARRAY_ROWS`/`NUM_COLS`/`M_TILE`/`PSUM_WIDTH`), K-dim tiling, numerics, and the software stack |
| [`protocol.md`](protocol.md) | The legacy core's wire protocol: every command, the tiling flags, status codes, SPI vs. UART PHY, and the firmware-local `FW_*` commands |
| [`pico2-ice.md`](pico2-ice.md) | iCE40UP5K target reference: build knobs, flash order, the five hard-won gotchas, the bisect ladder |
| [`performance.md`](performance.md) | Measured numbers: the DE1-SoC (MNIST in 109.5 µs, tile rate), then the pico2-ice's 8.0 s → 63.8 ms trail, LC/DSP budget, hardware vs. laptop |
| [`utilization.md`](utilization.md) | The legacy core's measured array utilization and wire composition, and the instruction-stream design they motivated |
| [`verification.md`](verification.md) | The legacy core's four tiers, the instruction-stream core's model, sim, self-test, board and application tiers, and what to run before trusting a change |
| [`mnist.md`](mnist.md) | The demo model: shape, quantization, the int16 accumulator constraint, accuracy, and how it runs on each board |
| [`repo-map.md`](repo-map.md) | Every directory and file, and what it's for |
| [`backlog.md`](backlog.md) | Open work, in rough value order |

## Conventions

- **Measured, not estimated.** Any number here came from running the thing.
  Where a figure is a projection, it says so.
- **Present tense describes what ships.** Superseded designs and retracted
  conclusions live in `performance.md`'s history section, clearly dated —
  not as present-tense claims elsewhere.
- **The source is authoritative for protocol details.**
  [`protocol.md`](protocol.md) is the legacy wire protocol, implemented by
  `rtl/core/tpu_sequencer.sv`. The instruction encoding lives in one field
  table, `host/tpu/isa.py`, mirrored by `rtl/isa/isa_pkg.sv`.
- **Sim vs hardware is always said.** A result is labelled as Verilator or
  model, or as measured on a board.
- **Code comments are sparse on purpose.** They mark decisions and low-level
  traps next to the code; the explanations live here.
