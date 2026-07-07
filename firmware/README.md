# firmware/ — RP2350 USB↔UART bridge for pico2-ice

This folder builds `pico2_ice_bridge.uf2`, the firmware that runs on the
pico2-ice board's Raspberry Pi RP2350. It is **not** the TPU design itself —
the TPU datapath is the Verilog under `../rtl/`, synthesized to a bitstream by
`../fpga/`. This firmware's only job is to get bytes from the host PC to the
iCE40 FPGA and back, and to get the FPGA a clock and its configuration in the
first place. See `../docs/FPGA.md` for the full architecture writeup and
build/flash/validate runbook; this file just covers what lives in this
directory.

## Why this exists

pico2-ice has two chips: the RP2350 (MCU) and an iCE40UP5K (FPGA). The FPGA
has no USB, no crystal, and no way to load its own configuration — so the
RP2350 has to:

1. Export a clock to the FPGA (`clk`, iCE40 pin 35, driven over a board trace
   from the RP2350's `GPOUT0`, not a crystal),
2. Push the bitstream (`../fpga/tpu_top.bin`) onto the FPGA over USB-DFU,
3. Bridge the FPGA's UART pins (iCE40 pins 9/11) to a USB-CDC serial port so
   `../tpu_host.py` on the PC can talk to `tpu_sequencer.sv`'s wire protocol.

This firmware is a small, deliberately minimal fork of
`pico-ice-sdk/examples/rp2_usb_uart` that does exactly those three things and
nothing else — it does not parse or interpret any of the bytes it bridges.

## Files

- **`main.c`** — the entire program. In order:
  - `uart_init(uart0, 115200)` + `gpio_set_function()` on **GPIO28/GPIO29**
    for the FPGA-facing UART. This is the one thing changed from the pin
    numbers in the upstream example: GPIO0/GPIO1 (what the RP2040-based
    original pico-ice uses) are wired to the onboard LEDs (`LED_G`/`LED_R`) on
    pico2-ice, not the FPGA — confirmed against the board schematic. Getting
    this wrong produces total silence on both USB-CDC ports.
  - `ice_usb_init()` — brings up the composite USB device described by
    `usb_descriptors.c` (two CDC-ACM ports + one DFU interface).
  - `ice_fpga_init(FPGA_DATA, AS_MHZ(12))` — exports a **12 MHz** clock to the
    FPGA over `GPOUT0`, instead of the SDK's 48 MHz default. This number is
    not a free choice: `tpu_top`'s measured fMax on the UP5K is ~32 MHz, and
    whatever frequency is requested here **must** numerically match
    `CLK_FREQ` in `../fpga/Makefile`, since that value sets the UART
    baud-rate divider computed at synthesis time. A mismatch produces garbled
    UART bytes, not an obvious failure — this is the single most common
    "board looks alive but nothing responds correctly" bug on this board.
  - `ice_fpga_start(FPGA_DATA)` — lets the FPGA start configuring from the
    bitstream flashed by `../fpga/Makefile`'s `prog` target.
  - `ice_fpga_configured(FPGA_DATA)` — polls the real `CDONE` pin and drives
    the onboard LED (green = FPGA configured and running, red = it isn't).
    This function exists in `pico-ice-sdk/src/ice_fpga.c` but isn't declared
    in the SDK's public header or used by any upstream example. It's used
    here deliberately, because the SDK's own DFU manifest-complete callback
    (`ice_usb.c`) reports `ok = ice_fpga_start(...)`, and `ice_fpga_start()`
    unconditionally `return 0;` — never actually checking `CDONE` — so that
    callback reports a bogus "firmware corrupt" error on **every** flash,
    success or failure. The LED driven from `ice_fpga_configured()` is the
    real signal; the DFU error message is a known false alarm (see
    `../docs/FPGA.md` §8.3).
  - `while (true) { tud_task(); }` — the TinyUSB device-stack service loop;
    everything else (the actual CDC↔UART forwarding) happens inside
    `pico-ice-sdk`'s USB callbacks, driven by this loop.

- **`usb_descriptors.c`** — TinyUSB descriptor tables for the composite USB
  device (forked from the tinyusb.org/TinyVision.ai example, MIT-licensed):
  - Two CDC-ACM interfaces, string-labeled `"RP2040 logs"` (`ITF_NUM_CDC0`)
    and `"iCE40 UART"` (`ITF_NUM_CDC1`). **`"iCE40 UART"` is the one
    `tpu_host.py --port` / `tests/hw_regression.py --port` needs to point
    at** — it's the port bridged to the FPGA's UART pins. `"RP2040 logs"` is
    a separate debug channel that doesn't speak `tpu_sequencer.sv`'s wire
    protocol at all.
  - One DFU interface (`ITF_NUM_DFU`) with two alt settings, string-labeled
    `"iCE40 DFU (Flash)"` and `"iCE40 DFU (CRAM)"` — used by `dfu-util` /
    `make prog` (in `../fpga/Makefile`) to push the FPGA bitstream.
  - **Gotcha**: on macOS, `pyserial`'s `list_ports.comports()` shows the
    overall USB *product string* (`pico-ice`) for both CDC interfaces, not
    these per-interface descriptions — so the two resulting
    `/dev/cu.usbmodemN` devices look identical from the port list alone.
    There's no reliable way to tell them apart programmatically on macOS;
    see `../docs/FPGA.md` §7.5/§8.5 for the trial-and-error approach
    (try the higher-numbered port first).

- **`tusb_config.h`** — TinyUSB device-stack configuration:
  - `CFG_TUD_CDC 2`, `CFG_TUD_DFU 1` + `CFG_TUD_DFU_ALT 2` — enables exactly
    the two CDC ports and the one DFU interface (two alt settings) that
    `usb_descriptors.c` declares.
  - `ICE_USB_UART0_CDC 1` — the pico-ice-sdk flag that makes `ice_usb_init()`
    automatically bridge the RP2350's `uart0` hardware peripheral to the
    second CDC port (`"iCE40 UART"`), byte-for-byte, with no firmware-side
    parsing.
  - CDC/DFU buffer sizes (512 B CDC FIFOs/endpoints, 256 B DFU transfer
    buffer — must be a multiple of the flash page size).

- **`CMakeLists.txt`** — build definition for the `pico2_ice_bridge`
  executable:
  - Points `PICO_ICE_SDK_PATH` at `pico-ice-sdk` (this same directory) —
    this project lives at `TPU/firmware/` rather than inside the SDK's own
    `examples/` tree, unlike the SDK's examples which symlink
    `pico-ice-sdk/`/`pico-sdk/` into each example directory.
  - Imports `pico-sdk` from inside that vendored SDK checkout via
    `pico_sdk_import.cmake`.
  - Builds `main.c` + `usb_descriptors.c` into `pico2_ice_bridge`, linked
    against `pico_ice_sdk` and `pico_ice_usb`.

- **`pico_sdk_import.cmake`** — the standard, unmodified `pico-sdk` CMake
  import boilerplate (a copy of the file the SDK ships at
  `external/pico_sdk_import.cmake`), included by `CMakeLists.txt` before
  `project()`.

- **`.gitignore`** — ignores `build/`, the out-of-tree CMake/Ninja build
  directory that produces `pico2_ice_bridge.uf2`.

## What's *not* here

- **`pico-ice-sdk/`** — the SDK this firmware depends on (`ice_usb`,
  `ice_fpga`, `ice_led`, and the underlying `pico-sdk`), tracked as a **git
  submodule** pinned to a specific upstream commit (see `.gitmodules` at the
  repo root). Fetch it with
  `git submodule update --init --recursive -- firmware/pico-ice-sdk`, or
  `git clone --recurse-submodules` when cloning this repo fresh
  (`../docs/FPGA.md` §6).
- **The FPGA bitstream/gateware.** That's `../fpga/` (RTL sources are
  `../rtl/*.sv`). This firmware doesn't know anything about the TPU protocol
  it's bridging — that logic lives entirely in `tpu_sequencer.sv` on the FPGA
  side and its mirror in `../tpu_host.py` on the host side.

## Building

```bash
cd firmware
mkdir -p build && cd build
cmake -DPICO_BOARD=pico2_ice -DPICO_PLATFORM=rp2350-riscv \
      -DPICO_GCC_TRIPLE=riscv64-unknown-elf -G Ninja ..
ninja           # -> pico2_ice_bridge.uf2
```

For an ARM build instead of RISC-V: `-DPICO_PLATFORM=rp2350-arm-s` (drop
`-DPICO_GCC_TRIPLE`), with `arm-none-eabi-gcc` on `PATH`.

Only needed once, or after changing something in this directory (e.g.
`CLK_FREQ`/pin numbers) — pure RTL changes under `../rtl/` never require a
firmware rebuild, only a gateware rebuild + reflash. Full flash/validate
sequence, including *why* firmware must be flashed before gateware, is in
`../docs/FPGA.md` §7.3–§7.5.
