# DE1-SoC with the HPS

`tpu_top` on the HPS lightweight bridge at **`0xFF200000`**, and a HEX display
register (`hex_pio`) at `0xFF210100`, inside
Terasic's rev H GHRD. The board's ARM Linux drives it through `/dev/mem`.

Only our pieces are tracked. Terasic's GHRD is extracted from the rev H System
CD into `build/` at build time.

| File | Role |
|---|---|
| `tpu_hw.tcl` | Platform Designer component: Avalon-MM slave, word addressing, read latency 1, waitrequest on writes |
| `add-tpu.tcl`, `patch_top.py` | `qsys-script` edit: add `tpu` at offset 0 of `h2f_lw` and `hex_pio` at `0x10100`, both on `clk_0`; then wire `hex_pio` to `hex_display` in Terasic's `ghrd_top.v` |
| `Makefile` | extract the GHRD → add the TPU and `hex_pio` → `qsys-generate` → compile → uncompressed `.rbf`; also builds `isa_mmio` and `setbaud` |
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
