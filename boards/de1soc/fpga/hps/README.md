# DE1-SoC with the HPS

`tpu_isa_top` on the HPS lightweight bridge at **`0xFF200000`**, inside
Terasic's rev H GHRD. The board's ARM Linux drives it through `/dev/mem`.

Only our pieces are tracked. Terasic's GHRD is extracted from the rev H System
CD into `build/` at build time.

| File | Role |
|---|---|
| `tpu_isa_hw.tcl` | Platform Designer component: Avalon-MM slave, word addressing, read latency 1, waitrequest on writes |
| `add_tpu.tcl` | `qsys-script` edit: add the component on `clk_0`, at offset 0 of `h2f_lw` |
| `Makefile` | extract the GHRD → add the TPU → `qsys-generate` → compile → uncompressed `.rbf`; also builds `isa_mmio` |
| `../../sw/isa_mmio.c` | ARM register server speaking `tb_isa`'s protocol, so `IsaDevice` drives the board as it drives Verilator |

## Build (in the OrbStack `quartus` VM)

```sh
make CD_ZIP=<path>/DE1-SoC_v.6.0.0_HWrevH_SystemCD.zip   # -> build/soc_system.rbf, build/isa_mmio
```

## Board setup

- **Board:** rev H. Its USB-UART is a CP2105 with two ports: "Enhanced" is the HPS console, "Standard" goes to FPGA pins.
- **SD card:** Terasic's "Linux Console with framebuffer" image (2014, kernel 3.12). U-Boot loads `soc_system.rbf` from the FAT partition at boot.
- **MSEL (SW10):** `00000`, positions 1–5 ON.
- **Deploy:** copy `soc_system.rbf` and `isa_mmio` onto the FAT partition. Keep Terasic's original as `soc_system_terasic.rbf`.
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
