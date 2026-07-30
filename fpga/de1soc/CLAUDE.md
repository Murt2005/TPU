# fpga/de1soc/ — Cyclone V target (IN PROGRESS)

**Nothing here has run on a DE1-SoC.** This is the second target, still being
brought up. If the task at hand is pico2-ice work, none of this applies — the
iCE40 target is `fpga/ice40/`.

## Status

| Piece | State |
|---|---|
| `rtl/tpu_top_hps.sv`, `rtl/hps_bridge.sv` | implemented, lint-clean, `make test-hps_bridge` passes |
| `tpu_host.py --link hps` (`MmioLink`) | implemented |
| 8×8 shape | sim-proven only (`make verilate-test`), 64 PEs on generic fabric |
| Quartus project here | scaffolding: `Makefile`, `.sdc`, `.qsf` skeleton |
| Qsys/GHRD integration | **not done** |
| Cloud build infra | **planned, not built** |
| On-board bring-up | **not started** |

Don't describe any of this as working or validated.

## How it differs from pico2-ice

Same board-neutral `tpu_core`. The host is the board's **ARM HPS**, not a
serial link: it reaches `hps_bridge` (Avalon-MM slave) over the lightweight
`h2f_lw` bridge at `0xFF200000`, and `tpu_host.py --link hps` runs **on the
board's own Linux**, driving it through `/dev/mem`.

| | |
|---|---|
| Device | `5CSEMA5F31C6N` (~85K LEs, ~87 DSPs, 397 M10K) |
| Fabric clock | `CLOCK_50` = `PIN_AF14`, 50 MHz |
| Reset | `KEY[0]` = `PIN_AA14`, active-low |

## Constraints that bite

- **`USE_MAC16_PAIR=0`, always.** `rtl/pe_pair.sv` hand-instantiates Lattice
  `SB_MAC16` and is iCE40-only. Cyclone V infers its own DSPs from `pe.sv`.
- **`hps_bridge` does no CDC.** Its `clk` must be the same fabric clock the
  `h2f_lw` bridge uses — single clock domain only.
- Avalon slave settings must be **fixed read latency 1, no waitrequest**, to
  match `hps_bridge.sv`.
- The base address must be **page-aligned** (`MmioLink` mmaps it).
- `Makefile` needs `PROJECT`/`REVISION` set to match the GHRD project before
  it will do anything.

## Build reality

**Quartus has no macOS build.** The `.rbf` is produced on x86-64 Linux —
currently by hand, eventually on ephemeral EC2 from a pre-baked Quartus AMI.
Don't suggest running Quartus locally on this machine, and don't invent
progress on the cloud build: it is a plan, not an implementation.

The integration path reuses Terasic's **DE1-SoC GHRD**, which already
instantiates the HPS, exports `h2f_lw`, and carries the HPS/DDR3 pin
assignments — the TPU is one added component, not a from-scratch system.

## Files

| File | What |
|---|---|
| `README.md` | The Quartus/Qsys integration + HPS deploy runbook — read this first |
| `Makefile` | `quartus_map`→`fit`→`asm` + `.sof`→`.rbf` |
| `tpu_top_hps.sdc` | 50 MHz fabric clock constraint |
| `tpu_top_hps.qsf` | Device + TPU-specific assignments (the rest come from the GHRD) |

Build outputs (`db/`, `incremental_db/`, `output_files/`, `*.rbf`, `*.sof`,
`*.rpt`, `*.qws`) are gitignored.

@../../docs/de1soc.md
