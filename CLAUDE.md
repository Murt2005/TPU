# TPU — from-scratch SystemVerilog TPUv1 reimplementation

Weight-stationary systolic array in synthesizable SystemVerilog, running on
real hardware. Two FPGA targets: pico2-ice (iCE40UP5K, done) and DE1-SoC
(Cyclone V, in progress).

## Two chips, and the flash order

pico2-ice carries **two** programmable chips. Both need their own image:

| Chip | Runs | Image |
|---|---|---|
| iCE40UP5K (FPGA) | the TPU gateware | `fpga/ice40/tpu_top.bin` |
| RP2350 (MCU) | USB bridge **+ the FPGA's clock + its bitstream loader** | `firmware/build*/pico2_ice_bridge.uf2` |

**Firmware first, gateware second — always.** The RP2350 supplies the FPGA's
clock and loads its bitstream, so with no firmware there is no clock, no
`CDONE`, and nothing listening on the DFU interface `dfu-util` needs.

Pure RTL changes need only a gateware reflash. Firmware reflash is rare.

## Commands

```bash
make test                 # all 22 testbenches (iverilog); make test-<name> for one
make lint                 # verilator --lint-only, 4 configs (UART/SPI/4x4-pair/HPS)
make verilate-test        # full-chip C++ sim, 7 shape+PHY combos
make hw-test PORT=/dev/cu.usbmodemXXXX \
     ARRAY_ROWS=4 NUM_COLS=4 M_TILE=2 LINK=spi   # real silicon; args must match the bitstream
make list                 # every registered test target
```

FPGA build, from `fpga/ice40/`:

```bash
make        # -> tpu_top.bin        make json   # yosys synth only
make asc    # nextpnr P&R only      make bin    # icepack only
make stat   # yosys cell counts     make util   # nextpnr device utilisation
make time   # icetime fMax          make prog   # flash over USB DFU
make clean
```

Build knobs (all `chparam`'d in at synthesis; hosts must be told the same):
`CLK_FREQ` `BAUD_RATE` `ARRAY_ROWS` `NUM_COLS` `M_TILE` `USE_SPI`
`USE_MAC16_PAIR` `ABC_FLAGS`.

**No hosted CI, by deliberate choice.** Quality gates are local `make`
targets. Never add `.github/workflows`.

## Gotchas that waste hours

- **`dfu-util` reports "Device's firmware is corrupt" on every gateware
  flash**, success or failure — an SDK bug (`ice_fpga_start()` returns 0
  unconditionally and never polls `CDONE`; 0 is falsy). Ignore it. The
  **LED** is the real signal: green = configured, red = not.
- **`CLK_FREQ` and `BAUD_RATE` are coupled across two files.** The FPGA's
  clock comes from the RP2350's `GPOUT0`, not a crystal, and the UART baud
  divider is baked in at synthesis. `fpga/ice40/Makefile`'s `CLK_FREQ` must
  match `firmware/main.c`'s `ice_fpga_init()` request, and `BAUD_RATE` must
  match `tpu_host.py`'s. Mismatch symptom: **garbled bytes, not silence.**
- **Replug the board after a gateware flash.** The FPGA reconfigures; the USB
  stack doesn't reliably follow without a power-cycle.
- **The two USB-CDC ports are indistinguishable** from the port list —
  macOS/pyserial shows the product string for both, not the per-interface
  description. The TPU is on the `iCE40 UART` one. Try one; if `--selftest`
  fails, try the other.
- **Host flags must match the flashed bitstream** (`--rows/--cols/--m-tile
  --link`), not the Makefile defaults. A mismatch fails on frame length.

## Layout

```
rtl/         datapath + control + 3 host PHYs; tpu_core.sv is board-neutral
tests/       22 SV testbenches + hw_regression.py + verilator/ C++ bench
fpga/ice40/  yosys -> nextpnr-ice40 -> icepack; all build knobs live here
fpga/de1soc/ Quartus scaffolding (in progress)
firmware/    RP2350 bridge; pico-ice-sdk is a git submodule
mnist/       144->64->10 int8 demo: train, infer, draw
tpu_host.py  host driver + CLI; UART / SPI / HPS-MMIO backends
docs/        design reference (see below)
olddocs/     pre-reorg archive, gitignored — do not edit or resurrect
```

## Status

pico2-ice is **hardware-validated** at 2×2, 2×4, and 4×4 (`make hw-test`
14/14 at each); MNIST runs end-to-end on silicon at ~63.8 ms/image, 19/20 on
the sampled set. DE1-SoC is **in progress** — RTL and host transport are
implemented and sim-tested, Quartus build and on-board bring-up are not done.

README.md §6 has the full status detail; don't restate it elsewhere.

## Conventions

- One short, focused commit per completed task. No `Co-Authored-By` trailer.
- `docs/` is committed. `olddocs/` is not — never stage it.
- Don't rewrite measured results or status claims in `docs/` unprompted; if
  a new measurement belongs there, say so rather than silently editing.
- Verify before asserting: `make test` + `make lint` for RTL changes, and
  `make hw-test` for anything touching synthesis, primitives, or memory
  inference — that is the only tier that validates the netlist.

## Reference

@docs/architecture.md
@docs/protocol.md
@docs/verification.md
