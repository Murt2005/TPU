# DE1-SoC with the HPS

`tpu_top` on the HPS lightweight bridge at **`0xFF200000`**, and a HEX display
register (`hex_pio`) at `0xFF210100`, inside
Terasic's rev H GHRD. The board's ARM Linux drives it through `/dev/mem`.

Only our pieces are tracked. Terasic's GHRD is extracted from the rev H System
CD into `build/` at build time.

| File | Role |
|---|---|
| `tpu_hw.tcl` | Platform Designer component: Avalon-MM slave, word addressing, read latency 1, waitrequest on writes |
| `ddr_probe_hw.tcl` | Platform Designer component for `top/ddr-probe.sv`: a 128-bit burst-read master, registers on `h2f_lw` |
| `add-tpu.tcl`, `patch_top.py` | `qsys-script` edit: add `tpu` at offset 0 of `h2f_lw`, `hex_pio` at `0x10100` and `ddr_probe` at `0x40000`, all on `clk_0`, plus a 128-bit FPGA-to-SDRAM port (`f2h_sdram0`) for the probe; then wire `hex_pio` to `hex_display` in Terasic's `ghrd_top.v` |
| `Makefile` | extract the GHRD → add the TPU, `hex_pio` and the probe → `qsys-generate` → compile → uncompressed `.rbf`; also builds `isa_mmio`, `setbaud` and `ddr_probe` |
| `../../sw/isa-mmio.c` | ARM register server speaking `tb_isa`'s protocol, so `IsaDevice` drives the board as it drives Verilator |
| `u-boot-ddr.txt`, `../../sw/mk-uboot-scr.py` | the boot script (`u-boot.scr`) that loads `soc_system_ddr.rbf` with the FPGA-to-SDRAM port live and `mem=768M` |
| `../../sw/ddr-boot.py` | the same boot by hand, for a bitstream loaded over JTAG |
| `../../sw/recv.c` | block-wise receiver for fast console uploads |

## Build (in the OrbStack `quartus` VM)

```sh
make CD_ZIP=<path>/DE1-SoC_v.6.0.0_HWrevH_SystemCD.zip   # -> build/soc_system.rbf, build/isa_mmio, build/setbaud
```

## Board setup

- **Board:** rev H. Its USB-UART is a CP2105 with two ports: "Enhanced" is the HPS console, "Standard" goes to FPGA pins.
- **SD card:** Terasic's "Linux Console with framebuffer" image (2014, kernel 3.12). U-Boot loads `soc_system.rbf` from the FAT partition at boot.
- **MSEL (SW10):** `00000`, positions 1–5 ON.
- **Deploy:** copy `soc_system.rbf`, `isa_mmio` and `setbaud` onto the FAT partition from the Mac. Keep Terasic's original as `soc_system_terasic.rbf`. Small files can also go over the console with `BoardConsole.upload()` (paced at 4 KB/s); bitstreams go on the card.
- **Ethernet:** on this image and board revision, the link comes up but receives nothing. Everything runs over the console instead.

## The FPGA-to-SDRAM port

U-Boot 2013.01 leaves every FPGA-to-SDRAM port in reset (`fpgaportrst`,
`0xFFC25080`, = 0) and never sets `applycfg`, so the SDRAM controller doesn't
take the port settings from a new bitstream. **Releasing the port from Linux
without `applycfg` hangs the whole HPS on the first read through it.** Both
have to happen in U-Boot, before Linux runs, and `applycfg` only while the
controller is idle: U-Boot runs from SDRAM, and a plain `mw` to it hung the
HPS once in three tries. It runs from ten instructions in on-chip RAM instead,
as later U-Boots do.

**At every boot, from the SD card:** `u-boot.scr` and `soc_system_ddr.rbf`
on the FAT partition (`make uboot-scr` builds `build/u-boot.scr` from
`u-boot-ddr.txt`, with `../../sw/mk-uboot-scr.py` in place of mkimage).
U-Boot's `bootcmd` sources `u-boot.scr` before its default boot; the script
loads `soc_system_ddr.rbf`, does the steps below and boots, so the default
never runs. Without `soc_system_ddr.rbf` it does nothing; deleting
`u-boot.scr` goes back to the default boot (`soc_system.rbf`, no port, all
1 GB to Linux). Send both with `BoardConsole.upload(..., fast=True,
receiver="/mnt/boot/recv")`: `recv` (`make recv`) reads in blocks, so the
7 MB bitstream takes about a minute, where `dd bs=1` would take half an hour.

**For a bitstream not on the card:** `boards/de1soc/sw/ddr-boot.py <console
port> <rbf>` does the same without touching the SD card: reboot into U-Boot, load the bitstream over JTAG, `run
mmcload`, apply the configuration from on-chip RAM, `run
bridge_enable_handoff`, release `f2h_sdram0` (`mw ffc25080 133`), and boot
with `mem=768M` (`bootz`, not `mmcboot`, which would reset `bootargs`).
`mem=768M` keeps Linux out of `0x30000000` and up, so the host can put
weights and activations there. Terasic's console framebuffer sits at
`0x3F000000` regardless, so `isa_mmio` reads and writes DDR3 only in
`[0x30000000, 0x3F000000)`. `ddr-boot.py` saves nothing: after a power
cycle the card's boot runs again.

Then, from the Mac, `python boards/de1soc/sw/ddr-probe.py <console port>`.
It checks the probe's checksum against the ARM's over the same physical range,
then sweeps burst length × bursts in flight, idle and under ARM memory load.
The probe only reads, so it needs no memory reserved from Linux.

## Running the tests on the board

On the board, `mount /dev/mmcblk0p1 /mnt/boot`. Then from the Mac:

```sh
python3 tests/isa/test_isa_rtl.py serial:/dev/cu.usbserial-<id>0:/mnt/boot/isa_mmio
```

`IsaSerialLink` logs in, silences kernel messages, starts `isa_mmio` and syncs
on its echo. At 115200 baud the full suite takes about 15 minutes.

Cycle differences aren't measurable over this link, so that one check is
limited to beats and WSTALL there. The rate itself is checked on chip by
`../selftest`.
