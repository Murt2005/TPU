# docs/

Design and reference documentation for this repo's from-scratch TPUv1-style
accelerator. The root [`README.md`](../README.md) is the entry point: it owns
the quick start. These files are the layer beneath it, the *why* and the
measured detail.

## Reading order

Want to run it:
1. Root [`README.md`](../README.md) §1, the DE1-SoC quick start.
2. [`de1soc.md`](de1soc.md): the board, the toolchain, both build flows, the gotchas.

Want to understand it:
1. [`architecture.md`](architecture.md): the hardware, module by module.
2. [`isa.md`](isa.md): the instruction set, registers and layouts.
3. [`performance.md`](performance.md): measured numbers.
4. [`utilization.md`](utilization.md): why the first core's array idled, which is what this one fixes.

Working on the code:
- [`repo-map.md`](repo-map.md): file by file.
- [`verification.md`](verification.md): what to run before trusting a change.
- [`backlog.md`](backlog.md): what's open.

## Index

| File | What's in it |
|---|---|
| [`architecture.md`](architecture.md) | The core: control vs datapath, every module and its latency, the memories and their port priorities, overlapped tiles, the requantizer, parameters, the board wrapper, the software around it |
| [`isa.md`](isa.md) | The programmer's view: the 64-bit instructions and fields, the engines, `WAIT`/`SIGNAL`, decode errors, data layouts, the `host_bridge` register map, the requantizer's arithmetic, compiling an MLP |
| [`de1soc.md`](de1soc.md) | The DE1-SoC: what runs on the board and what was measured, the rev H board and its two serial ports, Quartus in an OrbStack VM, the self-test and GHRD flows, the ARM programs, the gotchas |
| [`verification.md`](verification.md) | The ladder from unit benches to the board, what each tier sees, and what to run per change |
| [`performance.md`](performance.md) | The DE1-SoC numbers; then, as history, the first core's 8.0 s → 63.8 ms trail on the pico2-ice |
| [`utilization.md`](utilization.md) | History: the first core's measured array utilization and wire composition, and the instruction-stream design they motivated |
| [`mnist.md`](mnist.md) | The demo model: shape, quantization, accuracy, how it runs on the board |
| [`repo-map.md`](repo-map.md) | Every file and what it's for |
| [`backlog.md`](backlog.md) | Open work, in rough value order |

## Conventions

- **Measured, not estimated.** Any number here came from running the thing,
  and says whether that was in simulation or on the board. Where a figure is a
  projection, it says so.
- **Present tense describes what ships.** The first core and the pico2-ice
  are history: their code is at the git tag `pico2-ice-final`, and
  `performance.md` and `utilization.md` keep their numbers, marked as such.
- **One source for the encoding.** The instruction fields live in one table,
  `host/tpu/isa.py`, mirrored by `rtl/common/tpu-pkg.sv`.
- **Code comments are sparse on purpose.** They mark decisions and low-level
  traps; the explanations live here.
