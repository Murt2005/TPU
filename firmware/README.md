# firmware/ — RP2350 bridge for pico2-ice

This folder builds `pico2_ice_bridge.uf2`, the firmware that runs on the
pico2-ice board's Raspberry Pi RP2350. It is **not** the TPU design itself —
the TPU datapath is the SystemVerilog under `../rtl/`, synthesized to a
bitstream by `../fpga/ice40/`. This firmware's job is to get bytes from the
host PC to the iCE40 FPGA and back, and to get the FPGA a clock and its
configuration in the first place. In SPI builds it can also run the whole
matmul tiling loop itself. See `../docs/pico2-ice.md` for the full target
reference and build/flash/validate runbook; this file covers what lives in
this directory.

## Why this exists

pico2-ice has two chips: the RP2350 (MCU) and an iCE40UP5K (FPGA). The FPGA
has no USB, no crystal, and no way to load its own configuration — so the
RP2350 has to:

1. Export a clock to the FPGA (`clk`, iCE40 pin 35, driven over a board trace
   from the RP2350's `GPOUT0`, not a crystal),
2. Push the bitstream (`../fpga/ice40/tpu_top.bin`) onto the FPGA over
   USB-DFU,
3. Bridge the TPU's host link to a USB-CDC serial port so `../tpu_host.py` on
   the PC can talk to `tpu_sequencer.sv`'s wire protocol. That link is either
   the FPGA's UART pins (default build) or the shared RP2350↔iCE40 SPI bus
   (`TPU_LINK_SPI=ON`).

It started as a minimal fork of `pico-ice-sdk/examples/rp2_usb_uart` and
still is one in spirit. Two things go beyond forwarding bytes: the SPI build
captures two firmware-local commands (`FW_PROBE`, `FW_MATMUL`) off the host
stream, and a one-byte LED command listener runs on the otherwise-unused
second CDC port.

## Two builds

| | UART build (default) | SPI build |
|---|---|---|
| CMake option | `TPU_LINK_SPI=OFF` | `TPU_LINK_SPI=ON` |
| Build dir (convention) | `build/` | `build-spi/` |
| FPGA clock | 12 MHz | 24 MHz (`TPU_TILE_FPGA_CLK_MHZ`) |
| Pairs with gateware | `USE_SPI=0 CLK_FREQ=12000000` | `USE_SPI=1 CLK_FREQ=24000000` |
| Host flag | `--link uart` | `--link spi` |
| `FW_MATMUL` offload | no | yes |

Keep both built. The UART one is the bisect fallback when the SPI path
misbehaves. **The FPGA clock requested here must equal the gateware's
`CLK_FREQ`** — for UART builds the baud divider is baked in at synthesis, so
a mismatch gives garbled bytes rather than an obvious failure.

## Files

- **`main.c`** — setup plus the main loop. In order:
  - *(UART build)* `uart_init(uart0, 115200)` + `gpio_set_function()` on
    **GPIO28/GPIO29** for the FPGA-facing UART. 115200 is only the boot
    default: the SDK's CDC line-coding callback re-tunes uart0 to whatever
    baud the host opens the port at (1 Mbaud for `tpu_host.py`). GPIO28/29,
    not the 0/1 the upstream example uses — on pico2-ice GPIO0/1 are the
    onboard LEDs (`LED_G`/`LED_R`), confirmed against the board schematic.
    Getting this wrong produces total silence on both USB-CDC ports.
  - `ice_usb_init()` — brings up the composite USB device described by
    `usb_descriptors.c` (two CDC-ACM ports + one DFU interface).
  - *(UART build)* two SDK bugs patched around, both of which bit this
    project on real hardware (`../docs/pico2-ice.md` §7):
    - the SDK's CDC→UART handler **silently drops bytes** once the 32-deep
      UART TX FIFO fills, so it is replaced with a blocking write
      (`cdc_to_uart0_blocking`) — backpressure goes to the host through
      TinyUSB's flow control instead;
    - the SDK's UART RX interrupt calls TinyUSB **from the ISR**, racing the
      main loop's `tud_task()`; at 1 Mbaud this wedged CDC and DFU until a
      power cycle. The ISR is replaced with a ring-buffer producer
      (`uart0_rx_to_ring`, 4 KB), drained to CDC from the main loop
      (`drain_ring_to_cdc`), which is then the only TinyUSB caller.
  - *(SPI build)* the TPU CDC port's per-byte callback is removed; the port
    is polled from the main loop by `tpu_tile_service()` instead.
  - `ice_fpga_init(FPGA_DATA, AS_MHZ(12 or 24))` — the FPGA clock over
    `GPOUT0`, instead of the SDK's 48 MHz default. `tpu_top`'s measured fMax
    on the UP5K is ~28–32 MHz depending on shape.
  - `ice_fpga_start(FPGA_DATA)` — lets the FPGA configure from the bitstream
    flashed by `../fpga/ice40/Makefile`'s `prog` target.
  - *(SPI build)* `tpu_tile_init()` — see below.
  - `ice_fpga_configured(FPGA_DATA)` — polls the real `CDONE` pin and drives
    the onboard LED (green = FPGA configured and running, red = it isn't).
    This function exists in `pico-ice-sdk/src/ice_fpga.c` but isn't declared
    in the SDK's public header or used by any upstream example. It's used
    here because the SDK's DFU manifest callback reports
    `ok = ice_fpga_start(...)`, and `ice_fpga_start()` unconditionally
    `return 0;` — never checking `CDONE` — so that callback reports a bogus
    "firmware corrupt" error on **every** flash, success or failure. The LED
    is the real signal (`../docs/pico2-ice.md` §5.1).
  - The main loop: `tud_task()`, then either `drain_ring_to_cdc()` (UART) or
    `tpu_tile_service()` (SPI), then one byte from CDC port 0: `b`/`B` turns
    the LED blue, `g`/`G` green. `mnist/draw_demo.py --led-port` uses this to
    signal "inference complete" without touching the TPU link.

- **`tpu_tile.c` / `tpu_tile.h`** — SPI builds only (compiled to nothing
  otherwise). Two jobs, both on `spi0` over the shared config bus:
  - **CDC↔SPI bridge.** Forwards the host's `[CMD][LEN][payload]` frames to
    the FPGA as MOSI writes. SPI is master-driven, so responses are
    *polled*: after a complete frame, the bridge clocks `0xFF` filler (the
    sequencer's `NOP`) and watches MISO for the first non-`0x00` byte, which
    is STATUS. It never polls mid-frame, since a filler byte would land in
    the payload. Clocks are capped by the FPGA core clock: write ≤ `CLK/6`
    (the sequencer's inter-tile window in `STREAM_RUN`), read ≤ `CLK/8`
    (the SCK synchronizer in `spi_slave.sv`) — 4 MHz / 3 MHz at 24 MHz.
  - **Firmware commands**, captured instead of forwarded
    (`../docs/protocol.md` §5): `0xF1 FW_PROBE` answers `[0xAA][0x02]['T']
    [ver]` so the host can detect offload support; `0xF0 FW_MATMUL` takes
    matmul dims plus raw W/bias/A in one bulk write, runs `tpu_host.py`
    `matmul_tiled()`'s exact tiling loop against the FPGA (`LOAD_BIAS` per
    output block, chained `STREAM_RUN` frames, zero-padding done during tile
    gather), and returns the whole int16 result — one USB round trip per
    matmul instead of one per frame. Results are bit-identical to the
    host-tiled path, A/B-checked in `tests/hw_regression.py`. It is
    int16-only and always applies ReLU, so `PSUM_WIDTH>16` or
    `act_bypass=True` fall back to the host path.
  - `tpu_tile_init()` also handles a bus quirk: the SPI flash shares the bus
    **and** the FPGA's chip-select net, so it is put into deep power-down
    (`0xB9`) at startup, and the `STATUS_ERR` the FPGA queues in response to
    that byte is drained.

- **`usb_descriptors.c`** — TinyUSB descriptor tables for the composite USB
  device (forked from the tinyusb.org/TinyVision.ai example, MIT-licensed):
  - Two CDC-ACM interfaces, string-labeled `"RP2040 logs"` (`ITF_NUM_CDC0`)
    and `"iCE40 UART"` (`ITF_NUM_CDC1`). **`"iCE40 UART"` is the one
    `tpu_host.py --port` / `tests/hw_regression.py --port` needs** — it
    carries the TPU link in both builds (the name is historical in SPI
    builds). `"RP2040 logs"` carries only the LED commands above.
  - One DFU interface (`ITF_NUM_DFU`) with two alt settings, string-labeled
    `"iCE40 DFU (Flash)"` and `"iCE40 DFU (CRAM)"` — used by `dfu-util` /
    `make prog` (in `../fpga/ice40/Makefile`) to push the FPGA bitstream.
  - **Gotcha**: on macOS, `pyserial`'s `list_ports.comports()` shows the
    overall USB *product string* (`pico-ice`) for both CDC interfaces, not
    these per-interface descriptions — so the two resulting
    `/dev/cu.usbmodemN` devices look identical from the port list alone.
    See `../docs/pico2-ice.md` §5.4 for the trial-and-error approach
    (try the higher-numbered port first).

- **`tusb_config.h`** — TinyUSB device-stack configuration:
  - `CFG_TUD_CDC 2`, `CFG_TUD_DFU 1` + `CFG_TUD_DFU_ALT 2` — exactly the two
    CDC ports and the one DFU interface (two alt settings) that
    `usb_descriptors.c` declares.
  - `ICE_USB_UART0_CDC 1` — the pico-ice-sdk flag that makes `ice_usb_init()`
    bridge the RP2350's `uart0` to the second CDC port (`"iCE40 UART"`).
    `main.c` then swaps out both directions of that bridge (above).
  - CDC/DFU buffer sizes (512 B CDC FIFOs/endpoints, 256 B DFU transfer
    buffer — must be a multiple of the flash page size).

- **`CMakeLists.txt`** — build definition for the `pico2_ice_bridge`
  executable:
  - Points `PICO_ICE_SDK_PATH` at `pico-ice-sdk` (a subdirectory here) —
    this project lives at `TPU/firmware/` rather than inside the SDK's own
    `examples/` tree, unlike the SDK's examples which symlink
    `pico-ice-sdk/`/`pico-sdk/` into each example directory.
  - Imports `pico-sdk` from inside that vendored SDK checkout via
    `pico_sdk_import.cmake`.
  - Builds `main.c` + `tpu_tile.c` + `usb_descriptors.c` into
    `pico2_ice_bridge`, linked against `pico_ice_sdk` and `pico_ice_usb`.
  - `option(TPU_LINK_SPI ...)` — selects the build variant above.

- **`pico_sdk_import.cmake`** — the standard, unmodified `pico-sdk` CMake
  import boilerplate, included by `CMakeLists.txt` before `project()`.

- **`.gitignore`** — ignores `build/`; the repo root's `.gitignore` covers
  every `firmware/build*/`, including `build-spi/`.

## What's *not* here

- **`pico-ice-sdk/`** — the SDK this firmware depends on (`ice_usb`,
  `ice_fpga`, `ice_led`, and the underlying `pico-sdk`), tracked as a **git
  submodule** pinned to a specific upstream commit (see `.gitmodules` at the
  repo root). Fetch it with
  `git submodule update --init --recursive -- firmware/pico-ice-sdk`, or
  `git clone --recurse-submodules` when cloning this repo fresh. Never edit
  it to fix a bug — work around it here, as `main.c` does.
- **The FPGA bitstream/gateware.** That's `../fpga/ice40/` (RTL sources are
  `../rtl/*.sv`). Apart from the two `FW_*` commands, this firmware knows
  nothing about the TPU protocol — that lives in `tpu_sequencer.sv` on the
  FPGA side and its mirror in `../tpu_host.py` on the host side.

## Building

```bash
# UART build -> build/
cd firmware && mkdir -p build && cd build
cmake -DPICO_BOARD=pico2_ice -DPICO_PLATFORM=rp2350-riscv \
      -DPICO_GCC_TRIPLE=riscv64-unknown-elf -G Ninja ..
ninja           # -> pico2_ice_bridge.uf2

# SPI build + matmul offload -> build-spi/
cd .. && mkdir -p build-spi && cd build-spi
cmake -DPICO_BOARD=pico2_ice -DPICO_PLATFORM=rp2350-riscv \
      -DPICO_GCC_TRIPLE=riscv64-unknown-elf -DTPU_LINK_SPI=ON -G Ninja ..
ninja
```

For an ARM build instead of RISC-V: `-DPICO_PLATFORM=rp2350-arm-s` (drop
`-DPICO_GCC_TRIPLE`), with `arm-none-eabi-gcc` on `PATH`. The first configure
builds `picotool` from source, so it is slow once.

**Flashing:** BOOTSEL + copy the `.uf2` is only needed the first time. After
that, opening the TPU serial port at **1200 baud** reboots the board into the
UF2 bootloader (the SDK's line-coding callback handles it). Flash firmware
**before** gateware — with no firmware the FPGA has no clock and there is no
DFU interface.

Only needed once, or after changing something in this directory — pure RTL
changes under `../rtl/` never require a firmware rebuild, only a gateware
rebuild + reflash. The full flash/validate sequence is in
`../docs/pico2-ice.md` §1 and §8.
