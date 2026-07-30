# firmware/ — RP2350 bridge for pico2-ice

Minimal fork of `pico-ice-sdk/examples/rp2_usb_uart`. Its job: USB bridging,
the FPGA's clock, the FPGA's bitstream, and LED status. It does **not** parse
the TPU protocol — except for the two `FW_*` commands below.

## Build

Two variants, two out-of-tree build dirs (keep both; the UART one is the
bisect fallback):

```bash
# UART bridge (default) -> build/
cd firmware && mkdir -p build && cd build
cmake -DPICO_BOARD=pico2_ice -DPICO_PLATFORM=rp2350-riscv \
      -DPICO_GCC_TRIPLE=riscv64-unknown-elf -G Ninja ..
ninja                                   # -> pico2_ice_bridge.uf2

# SPI bridge + matmul offload -> build-spi/
cmake ... -DTPU_LINK_SPI=ON -G Ninja ..
```

| Knob | Values | Note |
|---|---|---|
| `PICO_PLATFORM` | `rp2350-riscv` (default here) / `rp2350-arm-s` | ARM: drop `PICO_GCC_TRIPLE`, need `arm-none-eabi-gcc` on PATH |
| `PICO_GCC_TRIPLE` | `riscv64-unknown-elf` | RISC-V builds only |
| `PICO_BOARD` | `pico2_ice` | always |
| `TPU_LINK_SPI` | `OFF` (uart0) / `ON` (spi0) | must match the gateware's `USE_SPI` |

First configure builds `picotool` from source — slow once, fast after.

**Flashing:** BOOTSEL + copy the `.uf2` is only needed for the *first* flash.
After that, opening the TPU serial port at **1200 baud** reboots the board
into the UF2 bootloader.

## The vendored SDK

`pico-ice-sdk/` is a **git submodule** (pinned in `.gitmodules`), and
`pico-sdk` lives inside it at `pico-ice-sdk/lib/pico-sdk/`. `CMakeLists.txt`
points at it directly rather than symlinking per-example as the SDK's own
examples do.

```bash
git submodule update --init --recursive -- firmware/pico-ice-sdk
```

**Never edit the submodule to fix a bug — work around it here.** Two SDK bugs
already bit this project on real hardware, and both fixes live in `main.c`:

- The USB→UART bridge **silently drops bytes** once the RP2350's 32-deep UART
  TX FIFO fills — any frame > 32 bytes. `main.c` uses a blocking bridge
  write; `tpu_host.py` additionally paces >32-byte writes.
- `ice_usb_uart0_to_cdc()` calls TinyUSB device APIs **from the UART0 RX
  ISR**, with no locking under `CFG_TUSB_OS=OPT_OS_NONE`, racing the main
  loop's `tud_task()`. Rare at 115200; at 1 Mbaud it wedges CDC *and* DFU and
  needs a power cycle. `main.c` replaces it with a ring-buffer producer
  drained from the main loop, which is then the only TinyUSB caller.

A third SDK bug is cosmetic but wastes time: `ice_fpga_start()` returns 0
unconditionally, so the DFU manifest callback reports "firmware is corrupt"
on **every** gateware flash. `main.c` uses `ice_fpga_configured()` for a real
`CDONE` check on the LED instead.

## Facts that must stay in sync with the gateware

- **`ice_fpga_init(FPGA_DATA, AS_MHZ(n))` sets the FPGA's clock** — there is
  no crystal. It must equal `fpga/ice40/Makefile`'s `CLK_FREQ`. 12 MHz for
  UART builds, 24 MHz for SPI (`TPU_TILE_FPGA_CLK_MHZ`).
- **The FPGA-facing UART is GPIO28/29, not GPIO0/1.** The upstream example
  hardcodes 0/1, which are the LEDs on this board. Wrong pins = total silence
  on both CDC ports.
- SPI clocks are CLK-derived: write ≤ `CLK/6` (the sequencer's inter-tile
  window), read ≤ `CLK/8` (the 2FF SCK synchronizer). Raising either breaks
  `STREAM_RUN`'s timing assumption — see `docs/protocol.md` §3.

## Files

| File | What |
|---|---|
| `main.c` | The whole bridge: USB, FPGA clock+config, ring-buffered UART↔CDC, LED from real `CDONE`, and a one-byte LED command listener on the second CDC port (the MNIST draw demo) |
| `tpu_tile.c` / `.h` | `TPU_LINK_SPI` only: the SPI link plus `FW_PROBE` (0xF1) and `FW_MATMUL` (0xF0) — the whole `matmul_tiled()` loop moved onto the MCU |
| `usb_descriptors.c` | TinyUSB tables: two CDC-ACM ports (`RP2040 logs`, `iCE40 UART`) + DFU with two alt settings |
| `tusb_config.h` | Must match those descriptors; sets `ICE_USB_UART0_CDC` |

`FW_*` commands are **captured, never forwarded** — the FPGA never sees them,
and every sequencer command still passes through byte-identically, so
`hw_regression.py`'s raw-protocol cases double as pass-through coverage.

## Verifying

There is **no firmware simulation tier.** `make hw-test` against a real board
is the only gate. Always A/B `--no-offload` against the offloaded path after
touching `tpu_tile.c` — they must be bit-identical.
