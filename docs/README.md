# docs/

Design and reference documentation for this repo's from-scratch TPUv1
reimplementation. The root [`README.md`](../README.md) is the entry point —
it owns the quick start, the toolchain install, and the troubleshooting
table. These files are the layer beneath it: the *why* and the measured
detail, not the getting-started path.

## Reading order

New to the repo, want to run it on a board:
1. Root [`README.md`](../README.md) §1 — quick start.
2. [`pico2-ice.md`](pico2-ice.md) — when §1 isn't enough, or something breaks.

New to the repo, want to understand the design:
1. [`architecture.md`](architecture.md) — the whole system, top to bottom.
2. [`protocol.md`](protocol.md) — how the host talks to it.
3. [`performance.md`](performance.md) — where the time and the LUTs go.
4. [`utilization.md`](utilization.md) — how much of that the array actually uses.

Working on the code:
- [`repo-map.md`](repo-map.md) — file-by-file.
- [`verification.md`](verification.md) — what to run before trusting a change.
- [`backlog.md`](backlog.md) — what's still open.

## Index

| File | What's in it |
|---|---|
| [`architecture.md`](architecture.md) | The whole system: the four host paths, the datapath module by module, the sequencer FSM, the parameter model (`ARRAY_ROWS`/`NUM_COLS`/`M_TILE`/`PSUM_WIDTH`), K-dim tiling, numerics, the RTL that exists but isn't wired up, and the software stack (`tpu_host.py`, firmware, `software/mnist/`, `software/llm/`) |
| [`protocol.md`](protocol.md) | The host wire protocol as shipped: every command, the tiling flags, status codes, SPI vs. UART PHY, and the firmware-local `FW_*` commands |
| [`pico2-ice.md`](pico2-ice.md) | iCE40UP5K target reference: build knobs, flash order, the five hard-won gotchas, the bisect ladder |
| [`de1soc.md`](de1soc.md) | Cyclone V target: what's implemented, what's scaffolded, the cloud Quartus build plan |
| [`performance.md`](performance.md) | Current measured numbers, the 8.0 s → 63.8 ms trail, LC/DSP budget, hardware vs. laptop |
| [`utilization.md`](utilization.md) | Measured array utilization and wire composition, the unused double-buffering, and a command-interface / ISA design driven by both |
| [`verification.md`](verification.md) | The four verification tiers and what each one actually proves |
| [`mnist.md`](mnist.md) | The demo model: shape, quantization, the int16 accumulator constraint, accuracy |
| [`repo-map.md`](repo-map.md) | Every directory and file, and what it's for |
| [`backlog.md`](backlog.md) | Open work, in rough value order |

## Conventions

- **Measured, not estimated.** Any number here came from running the thing.
  Where a figure is a projection, it says so.
- **Present tense describes what ships.** Superseded designs and retracted
  conclusions live in `performance.md`'s history section, clearly dated —
  not as present-tense claims elsewhere.
- **The source is authoritative for protocol details.**
  [`protocol.md`](protocol.md) is the normative wire-protocol spec;
  `rtl/core/tpu_sequencer.sv` implements it.
- **Code comments are sparse on purpose.** They mark decisions and low-level
  traps next to the code; the explanations live here.
