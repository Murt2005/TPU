# DE1-SoC FPGA-only self-test

`tpu_top` driven by `replay`, a ROM-fed Avalon master, with no HPS,
Linux or SD card involved. The ROM is a register transcript of the
core's tests, with every expected word taken from the reference
model (`host/tpu/isa_model.py`). The board checks itself and reports on its
LEDs and HEX displays.

| Display | Meaning |
|---|---|
| `PASS`, LEDR0 | every check matched |
| LEDR1, HEX3..2 = mark, HEX1..0 = mismatch count | failed; marks are listed in `isa_selftest.marks` |
| LEDR2, HEX3..2 = mark | still running (a hang shows which test it's stuck in) |
| LEDR3 / LEDR4 | a `WAIT_DONE` timed out / the core raised ERR |
| LEDR9 | heartbeat, the clock is running |

KEY0 reruns it. A full run takes about 1 ms at 50 MHz.

With SW9 up, HEX5..0 show capture slot SW4..0 in hex: the perf counters after
the MNIST run and the tile-rate runs, listed in `isa_selftest.caps`. The rate
itself is checked on chip, so a regression fails the test. The replay is
cycle-exact, so every slot must equal `make selftest-sim ST_SLOTS=21`.

Quartus runs in an x86 Ubuntu machine under OrbStack (Rosetta). Its parallel
synthesis helpers deadlock there, so the `.qsf` sets `NUM_PARALLEL_PROCESSORS 1`.
The USB-Blaster II needs `blaster_6810.hex` from the Quartus install
(`quartus/linux64/`); pass it to openFPGALoader with `--probe-firmware`.

```sh
# on the Mac
make rom                                 # writes isa_selftest.hex (+ .marks)
make -C ../../../.. selftest-sim         # the same ROM through Verilator: must PASS
# in the x86 Linux VM, same path (OrbStack mounts /Users)
make                                     # quartus_sh --flow compile + .rbf
# on the Mac
openFPGALoader -b de1Soc --probe-firmware <path>/blaster_6810.hex output_files/tpu_selftest.rbf
```

`--index-chain 1`: the DE1-SoC's JTAG chain has the HPS's debug port first and
the FPGA second.
