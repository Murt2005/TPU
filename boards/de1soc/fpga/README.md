# DE1-SoC FPGA builds

Both builds run Quartus Prime Lite 23.1std.1 in the OrbStack x86 VM. Setup,
board settings and gotchas are in [`docs/de1soc.md`](../../../docs/de1soc.md).

| Directory | What it builds | Loaded by | Status |
|---|---|---|---|
| [`selftest/`](selftest/) | `tpu_top` + `replay`: the core's tests as a ROM transcript, results on LEDs/HEX, no HPS | JTAG, from the Mac (`openFPGALoader -b de1Soc`) | **PASS on the board** |
| [`hps/`](hps/) | Terasic's rev H GHRD + `tpu_top` at `0xFF200000` + a HEX display register at `0xFF210100`, driven by the ARM | U-Boot, from the SD card | **running on the board** |

Generated output (`db/`, `output_files/`, `build/`, the ROM files) is
gitignored. Terasic's GHRD is extracted from the System CD at build time, so
none of its files are in the repo.
