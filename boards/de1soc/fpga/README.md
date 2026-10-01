# DE1-SoC FPGA builds

All builds run Quartus Prime Lite 23.1std.1 in the OrbStack x86 VM, and are
programmed from the Mac with `openFPGALoader -b de1Soc`. Setup, board
settings and gotchas are in [`docs/de1soc.md`](../../../docs/de1soc.md).

| Directory | What it builds | Status |
|---|---|---|
| [`selftest/`](selftest/) | `tpu_isa_top` + `isa_replay`: the instruction-stream tests as a ROM transcript, results on LEDs/HEX, no HPS | **PASS on the board**; loaded over JTAG |
| [`hps/`](hps/) | Terasic's rev H GHRD + `tpu_isa_top` at `0xFF200000` + a HEX display register at `0xFF210100`, driven by the ARM | **Running on the board**; loaded by U-Boot from the SD card |
| this directory (`Makefile`, `tpu_top_hps.qsf`, `tpu_top_hps.sdc`) | the legacy byte-protocol core (`../top/tpu_top_hps.sv`, `hps_bridge`) | never built: the instruction-stream core replaced it as the DE1-SoC design |

Generated output (`db/`, `output_files/`, `build/`, ROM hex files) is
gitignored. Terasic's GHRD is extracted from the System CD at build time, so
none of its files are in the repo.
