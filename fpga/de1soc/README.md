# DE1-SoC (Cyclone V) build — HPS-driven TPU

> **Status: scaffolding, not yet hardware-validated.** The RTL half (the
> `tpu_top_hps` top, the `hps_bridge` Avalon-MM PHY, and the `tpu_host.py
> --link hps` transport) is written and simulation-tested (`make test-hps_bridge`,
> `make lint` HPS config). The Quartus project / Platform Designer system and
> the on-board bring-up below still need to be built and run in your Quartus
> environment — this directory gives you the constraints, the build automation,
> and the exact integration steps.

This target runs the same board-neutral `tpu_core` as the pico2-ice build, but
the host is the DE1-SoC's **ARM HPS** instead of a serial link: the HPS reaches
`hps_bridge` (a small Avalon-MM slave) over the **lightweight HPS→FPGA bridge
(`h2f_lw`, base `0xFF200000`)**, and `tpu_host.py --link hps` — running *on the
board's Linux* — drives it via `/dev/mem`.

## Why this layout (and no Quartus on your Mac)

Quartus Prime has no macOS build. You don't need one locally: build the
bitstream on any **x86-64 Linux** environment (a cloud VM is easiest on Apple
Silicon; a local VM is fine on Intel), produce a **`.rbf`**, copy it to the
board over the network, and let the **HPS configure the FPGA itself**. Your Mac
only ever needs `ssh`/`scp` — and since the host driver also runs on the board,
nothing board-facing happens on the Mac at all.

## Device / board facts

| Thing | Value |
|-------|-------|
| Device | `5CSEMA5F31C6N` (Cyclone V SoC; ~85K LEs, ~87 DSP blocks, 397 M10K) |
| Fabric clock | `CLOCK_50` = `PIN_AF14`, 50 MHz (matches `tpu_top`'s default `CLK_FREQ`) |
| Reset | `KEY[0]` = `PIN_AA14`, active-low (→ `reset_n`) |
| Host bridge | lightweight `h2f_lw`, base `0xFF200000`; `hps_bridge` at component offset `0x0` |

The array shape is a parameter (`ARRAY_ROWS`/`NUM_COLS`/`M_TILE`/`USE_MAC16_PAIR`
on `tpu_top_hps`). Build with **`USE_MAC16_PAIR=0`** — the `SB_MAC16` DSP-pair
path is iCE40-only; Cyclone V infers its own DSPs from `pe.sv`'s multiply. Start
at the current small shape to bring the flow up, then scale (see the repo
`docs/` and the top-level plan).

## Build steps (on x86-64 Linux with Quartus Prime Lite)

The cleanest path reuses Terasic's **DE1-SoC GHRD** (Golden Hardware Reference
Design), which already has the HPS instantiated, the `h2f_lw` bridge exported,
and all the HPS/DDR3 pin assignments done — so you only add one component.

1. **Start from the GHRD** for your Quartus version (Terasic "DE1-SoC CD-ROM" /
   `DE1_SoC_GHRD`). Open its Quartus project.
2. **Add the TPU RTL** to the project: every file in `../../rtl/*.sv` (they are
   board-neutral) plus this directory's `tpu_top_hps.sdc`. The relevant module
   is `tpu_top_hps` (see `../../rtl/tpu_top_hps.sv`).
3. **In Platform Designer (Qsys)**, open the GHRD's system and add `tpu_top_hps`
   as a component (or wrap `hps_bridge` alone as the Avalon slave and keep
   `tpu_core` in HDL — either works; the all-in-one `tpu_top_hps` is simplest):
   - Connect its Avalon-MM slave to the HPS **`h2f_lw`** master.
   - Assign it a **page-aligned base address** (offset `0x0` → absolute
     `0xFF200000`, which is `MmioLink`'s default; any page-aligned base works if
     you pass a matching `offset` to `MmioLink`).
   - Slave settings: **fixed read latency 1, no waitrequest** (matches
     `hps_bridge.sv`).
   - Clock its `clk` from the same fabric clock the `h2f_lw` bridge uses
     (single clock domain — no CDC is done in `hps_bridge`).
   - Wire `reset_n` to the system reset.
   - Regenerate the Qsys system (HDL generation).
4. **Compile**: `make` in this directory (wraps `quartus_map`/`fit`/`asm` and
   the `.sof`→`.rbf` conversion) once you have set `PROJECT`/`REVISION` at the
   top of the `Makefile` to match the GHRD project. Check timing closes at
   50 MHz in the Timing Analyzer (`tpu_top_hps.sdc` declares the clock).

## Deploy + run (from your Mac, over the network)

1. `scp output_files/<project>.rbf root@<board-ip>:/root/tpu.rbf`
2. On the board, configure the FPGA from the HPS — either:
   - **u-boot / SD boot:** put the `.rbf` on the SD FAT partition as the boot
     `.rbf` and reboot (u-boot `fpga load`), or
   - **at runtime** via the FPGA Manager (e.g. `dd if=/root/tpu.rbf
     of=/dev/fpga0`, exact device depends on your kernel/overlay).
3. Copy the host driver to the board and run it *there*:
   ```sh
   scp ../../tpu_host.py ../../requirements.txt root@<board-ip>:/root/
   # on the board (needs numpy + root for /dev/mem):
   python3 tpu_host.py --port /dev/mem --link hps --rows 2 --cols 2 --selftest
   ```
   `tests/hw_regression.py` and `mnist/infer.py` take the same `--link hps
   --port /dev/mem` and can also run on the board.

## Files here

- `Makefile` — Quartus command-line build (`quartus_map`→`fit`→`asm`) + `.rbf`
  generation. Set `PROJECT`/`REVISION` before use.
- `tpu_top_hps.sdc` — 50 MHz fabric clock constraint for the TPU logic.
- `tpu_top_hps.qsf` — device + key pin/settings skeleton (most HPS/DDR3
  assignments come from the GHRD; this documents the TPU-specific ones).
