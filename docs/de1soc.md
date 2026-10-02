# DE1-SoC (Cyclone V) target

**Status: hardware-validated.** The TPU core ([`architecture.md`](architecture.md),
[`isa.md`](isa.md)), with an 8×8 array at 50 MHz, runs on a DE1-SoC two ways:
- **On its own:** a self-checking bitstream, with results on the LEDs and HEX
  displays.
- **Behind the ARM:** the board's ARM drives it over the lightweight HPS→FPGA
  bridge. There it passes the full test suite and runs MNIST end to end in
  **109.5 µs/image**, with a drawing demo that shows the digit on the HEX
  displays.

The DE1-SoC is the repo's only target. The first core's pico2-ice (iCE40UP5K)
target was retired; it is preserved at the git tag `pico2-ice-final`.

## 1. What runs on the board

| Piece | Where | Measured on the board |
|---|---|---|
| FPGA-only self-test | `boards/de1soc/fpga/selftest/` | **PASS.** The core's tests as a ROM transcript replayed into it; tile rate checked on chip, every perf counter equal to Verilator |
| TPU behind the HPS | `boards/de1soc/fpga/hps/` | Terasic's rev H reference design (GHRD) plus `tpu_top` at `0xFF200000`, plus a HEX display register at `0xFF210100`. U-Boot loads it from the SD card |
| Full test suite from the ARM | `tests/isa/test_isa_rtl.py serial:<port>` | **Every functional test passes**: decode errors, 40 random layers, MNIST, requantizer sweeps, 40 random concurrent programs |
| MNIST on the ARM | `software/mnist/de1soc/` | 10,000 test images: **97.50%**, 10,000/10,000 equal to the reference model; **109.5 µs/image** end to end (m=1), 77.6 µs (m=8) |
| Drawing demo | `software/mnist/draw_demo.py --de1soc` | The digit appears on HEX0; 117 µs on the board, 7.5 ms round trip at 1.5625 Mbaud |

| Build | ALMs | RAM blocks | DSPs | Timing at 50 MHz |
|---|---|---|---|---|
| self-test (core + ROM) | 7,587 (24%) | 351 / 397 | 78 / 87 | met, 3.1 ns slack |
| GHRD + core + HEX | 9,637 (30%) | 339 / 397 | 78 / 87 | met, 3.4 ns slack |

78 of the 87 DSPs are used: 64 PE multipliers, 8 requantizer lanes, and the
tile-count products. That is what stands between 8×8 and 16×16 (§7).

These are the builds of the current `rtl/` (2026-10-01). The same core
before it moved out of `rtl/isa/` measured 6,635 ALMs for the self-test, with
identical synthesis (78 DSPs, the same memory bits and registers), and was
cycle-for-cycle the same on the board. The fitter packs the new module
boundaries a little differently. MNIST on that earlier build ran at 109.5
µs/image, and at 113.3 µs on the current one; the ARM's preprocessing alone,
which the RTL doesn't touch, moved by the same ~4%.

## 2. The board

| Thing | Value |
|---|---|
| Board | DE1-SoC **rev H**: the only revision with a CP2105 USB-UART, where earlier ones had an FT232R. The rev H System CD (6.0.0) has the matching GHRD |
| Device | `5CSEMA5F31C6` (Cyclone V SoC; 32,070 ALMs, 87 DSP blocks, 397 M10K) + dual Cortex-A9 HPS |
| Fabric clock | `CLOCK_50` = `PIN_AF14` |
| USB-Blaster II | JTAG. The chain is the ARM DAP at index 0, then the FPGA at index 1 |
| CP2105, "Enhanced" port | the HPS Linux console: 115200 baud, up to 2 Mbps on this side |
| CP2105, "Standard" port | wired to FPGA pins (`PIN_D9`/`PIN_E9`), **921,600 baud max** |
| MSEL (SW10, underside) | `10010` (default): the FPGA loads from on-board flash. **`00000`** (positions 1–5 ON): U-Boot loads `soc_system.rbf` from the SD card. JTAG works in either |
| microSD | Terasic's **"Linux Console with framebuffer"** image (2014, kernel 3.12, root with no password) |

On macOS the two CP2105 ports appear as `/dev/cu.usbserial-<id>0` (console)
and `…<id>1` (FPGA).

## 3. Toolchain (Apple Silicon Mac)

Quartus has no macOS build. It runs in an x86 Ubuntu 22.04 machine under
**OrbStack** (Rosetta), which mounts `/Users` at the same path, so the repo
is shared:

```sh
orb create --arch amd64 ubuntu:22.04 quartus
# in it: Quartus Prime Lite 23.1std.1, components quartus + cyclonev only
#   ./qinst-lite-linux-23.1std.1-993.run --nox11 -- --cli --accept-eula \
#     --install-dir ~/intelFPGA_lite/23.1std --components quartus,cyclonev
# plus: unzip, python3, gcc-arm-linux-gnueabihf (ARM programs)
```

From the Mac, run builds as
`orb -m quartus bash -c 'export PATH=$HOME/intelFPGA_lite/23.1std/quartus/bin:$PATH; cd <dir>; make'`.
A full compile takes about 10 minutes for the self-test and about 15 for the
GHRD.

**Programming over JTAG** happens on the Mac (`brew install openfpgaloader`).
The USB-Blaster II needs Intel's firmware file, which ships inside Quartus
(`quartus/linux64/blaster_6810.hex`):

```sh
openFPGALoader -b de1Soc --probe-firmware <path>/blaster_6810.hex <file>.rbf
```

This only configures the FPGA's SRAM; a power cycle clears it.

## 4. Flow A: the FPGA-only self-test

No SD card, no Linux, no host link. `replay` (a ROM-fed Avalon master)
plays a register transcript of the core's tests into the bridge
and checks every read. Every expected word comes from the reference model,
not the RTL.

```sh
make selftest-sim                          # Mac: build the ROM, run it in Verilator (must PASS)
make -C boards/de1soc/fpga/selftest        # VM: compile -> output_files/tpu-selftest.rbf
openFPGALoader -b de1Soc --probe-firmware … boards/de1soc/fpga/selftest/output_files/tpu-selftest.rbf
```

HEX3–0 show **`PASS`**, or else the failing test's mark and the mismatch
count. With SW9 up, SW4–0 select a perf-counter capture shown on HEX5–0. The
replay is cycle-exact, so each capture must equal the Verilator run. Details
in [`../boards/de1soc/fpga/selftest/README.md`](../boards/de1soc/fpga/selftest/README.md).

## 5. Flow B: the TPU behind the HPS

`boards/de1soc/fpga/hps/` adds the TPU to Terasic's rev H GHRD. Only our
pieces are tracked. The Makefile extracts the GHRD from the System CD zip
and then:
- runs `qsys-script` to add the `tpu` component at offset 0 and `hex_pio` at
  `0x10100`;
- patches `ghrd_top.v` to wire the HEX decoder;
- generates, compiles and converts to an uncompressed `.rbf`.

```sh
make -C boards/de1soc/fpga/hps CD_ZIP=<…>/DE1-SoC_v.6.0.0_HWrevH_SystemCD.zip   # VM
```

**Deploy.** Put `build/soc_system.rbf` on the SD card's FAT partition (from
the Mac, through a card reader), set MSEL to `00000` and boot; U-Boot loads it.

On a running board, small files (programs, data) can be pushed over the
console instead of moving the card. `tpu.isa_device.BoardConsole.upload()`
puts the tty in raw mode, receives with `dd bs=1`, and checks MD5. There's no
flow control, and `dd bs=1` onto FAT writes only about 6 KB/s, so the upload
paces itself at 4 KB/s: 371 KB took 95 s. A 7 MB bitstream sent unpaced lost
bytes and never finished, so bitstreams go on the card.

**Driving it.** There's no Python on the board's image. The ARM side is
static C:

| Program | Role |
|---|---|
| `boards/de1soc/sw/isa_mmio` | register server speaking `tb_isa`'s pipe protocol, so `IsaDevice` and the test suite drive the board exactly as they drive Verilator (`IsaSerialLink`) |
| `software/mnist/de1soc/mnist_tpu` | MNIST end to end: `bench` over the test set, `serve` for the drawing demo |
| `boards/de1soc/sw/setbaud` | sets console baud through `termios2` (no libc, 636 bytes), because busybox `stty` stops at 921,600 |

`tpu.isa_device.BoardConsole` turns the console into a launcher. It logs in,
silences kernel messages, mounts the boot partition at `/mnt/boot`, starts a
program, and syncs on its echo. After that, the line carries raw binary.

## 6. Gotchas — each one cost real time

| Symptom | Cause | Fix |
|---|---|---|
| Quartus synthesis sits idle for 15+ minutes after elaboration | Quartus's parallel helpers deadlock on their IPC pipes under Rosetta | `set_global_assignment -name NUM_PARALLEL_PROCESSORS 1` (in both projects) |
| 120 DSPs requested on an 87-DSP part | multiplies declared wider than their values: a 64×64 requantizer, 32/64-bit tile-count products | Give every product its real width (now 78 DSPs) |
| 4 ns short of 50 MHz, all in ACT | bias + ReLU + saturate + multiply + round + clamp in one cycle | Three ACT states for the requantizer |
| "Error reading Quartus Prime Settings File" | an appended line glued onto a `.qsf` that doesn't end with a newline (Terasic's and Quartus's both don't) | Start every append with `\n` |
| `pe.sv`'s `$fatal` checks in synthesis | Quartus doesn't define `SYNTHESIS` | `VERILOG_MACRO "SYNTHESIS=1"` |
| Ethernet links up but receives nothing, at 1 Gbit or 100 Mbit | the 2014 image on a rev H board (PHY found, TX works, RX gets 0 packets) | **Unsolved**; everything goes over the console instead |
| Binary protocol desyncs after launching a program | `\r\n` leaves a `\n` queued as the program's first byte; leftover shell output gets read as data | Launch with `\r`; Ctrl-C, wait for quiet, sync on the echoed command line |
| Echo sync fails on long commands | the console wraps lines past 80 columns | Compare with `\r`/spaces removed |
| `head -c` doesn't count bytes | this busybox's `head` has no `-c` (it errors) | `dd bs=1 count=N` |
| A big console upload never finishes | no flow control; `dd bs=1` onto FAT writes ~6 KB/s, so unpaced bytes overflow and are dropped | `upload()` paces at 4 KB/s; bitstreams go on the SD card |
| Console above 921,600 doesn't work | busybox `stty` doesn't know those rates; the HPS UART is 6.25 MHz / n | `setbaud`. 1,562,500 (÷4) links; 2,083,333 (÷3) doesn't |
| The FPGA CP2105 port can't do 2 Mbaud | the CP2105's Standard interface tops out at 921,600 | Use the HPS console port for speed |

## 7. What's next

See [`backlog.md`](backlog.md). Board-specific items:

- **Ethernet.** Probably needs a boot loader built from the rev H GHRD
  handoff, which takes SoC EDS, not just Quartus. It would only make updates
  faster; nothing depends on it.
- **Throughput beyond the console.** The ARM is now the host, so the serial
  link only matters for the demo. MNIST's remaining 109.5 µs is about half
  ARM float preprocessing (48.9 µs) and half lightweight-bridge register
  latency. The TPU work itself is about 29 µs per image in register traffic,
  and compute is a fraction of that.
- **A bigger array.** 16×16 needs the PE multiplies packed three per DSP
  block (Cyclone V's 9×9 mode) or partly in logic. 78/87 DSPs are used at
  8×8.
- **DDR3 (spec phase 5).** `RD_DDR_UB`, `SET_OBASE`, `MATMUL wsrc=1`,
  `ACTIVATE dst=DDR` are decoded and rejected as `UNIMPL`.
