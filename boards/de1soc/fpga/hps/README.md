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
without `applycfg` hangs the whole HPS on the first read through it.** Do both
in U-Boot instead, before Linux runs. Without touching the SD card:

1. Stop U-Boot's autoboot over the console (`reboot`, then a key during the countdown).
2. Load `build/soc_system.rbf` over JTAG while U-Boot waits.
3. In U-Boot, skipping `fpgaload` (it would reload the card's bitstream):
   ```
   run mmcload
   mw ffc2505c a                   # staticcfg.applycfg, self-clearing
   run bridge_enable_handoff
   mw ffc25080 133                 # f2h_sdram0's command, read and write ports out of reset
   run mmcboot
   ```

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
