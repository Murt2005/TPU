# FPGA.md — pico2-ice: architecture, code layout, and build/flash/validate guide

Everything about running the TPU RTL on a
[pico2-ice](https://pico2-ice.tinyvision.ai/) board (RP2350 + iCE40UP5K) in one
place: how the design actually runs on the FPGA and talks to the host, what
every file under `fpga/pico2_ice/` and `firmware/pico2_ice_bridge/` is for, the
full build/flash/validate runbook, and every gotcha found the hard way during
bring-up. Covers the open-source toolchain path (yosys/nextpnr-ice40/icepack),
not Quartus/DE1-SoC (see `README.md` §3.2 for that planned target).

For the sequencer FSM's cycle-by-cycle timing, see
`docs/sequencer_uart_design.md`.

## 1. The board: two chips, two independent images

pico2-ice puts two separate programmable chips on one board, and each needs
its own image on it before anything works:

| Chip | Role | Image | Built from |
|---|---|---|---|
| Lattice iCE40UP5K (FPGA) | Runs the TPU datapath itself | `fpga/pico2_ice/tpu_top.bin` (bitstream) | `rtl/*.sv` |
| Raspberry Pi RP2350 (MCU) | USB↔UART bridge + FPGA clock/config source | `firmware/pico2_ice_bridge/build/pico2_ice_bridge.uf2` | `firmware/pico2_ice_bridge/*` |

The RP2350 isn't just a USB-to-serial chip here — it also **drives the
FPGA's clock and loads its bitstream**. So the RP2350 firmware has to be
running correctly before the FPGA can do anything at all: no firmware means
no clock, no `CDONE`, and `dfu-util` has nothing listening on the DFU
interface it needs to push a bitstream to. This is why bring-up flashes
firmware *first*, gateware *second* (§7.3 below).

## 2. How the TPU RTL runs on the FPGA

### 2.1 Data flow

`tpu_top.sv` (`rtl/tpu_top.sv`) is the synthesis top level. It wires together
every other module in `rtl/` into one pipeline:

```
UART RX → sequencer → weight FIFO ─┐
                                    ├→ MMU (2×2 systolic array) → accumulator → bias → ReLU → UART TX
       unified buffer → systolic data setup ─┘
```

- **`uart_rx.sv` / `uart_tx.sv`** — 8N1 UART framing at the pins. This is the
  *only* I/O the FPGA has to the outside world on this board: no PCIe, no
  DDR3 (the things TPUv1 originally used) — just two GPIO pins bridged to USB
  by the RP2350.
- **`tpu_sequencer.sv`** — decodes the 5-command UART wire protocol (§3
  below) and orchestrates the rest of the pipeline cycle-by-cycle: writing
  activations into the unified buffer, streaming weights into the weight
  FIFO, pulsing `swap_banks`/`loading_phase`, kicking off the systolic read,
  and collecting/transmitting the result. This replaces what would be a
  testbench manually wiggling signals — in real operation, the sequencer
  *is* the control plane.
- **`unified_buffer.sv`** — on-chip double-banked SRAM holding the
  activation matrix. One bank feeds the systolic array while the other is
  writable, so back-to-back layers/tiles don't have to leave the chip.
- **`weight_fifo.sv`** (+ `fifo.sv`) — double-buffered (ping-pong) weight
  store: the *shadow* bank accepts the next weight tile over UART while the
  *active* bank still feeds the MMU during `loading_phase`.
- **`systolic_data_setup.sv`** — skews/staggers the activation row read out
  of the unified buffer so it arrives at each MMU row with the correct
  time offset for a systolic array.
- **`mmu.sv`** (+ `pe.sv`) — the actual 2×2 systolic array. Each `pe.sv`
  instance holds one stationary weight and multiply-accumulates a streaming
  activation against it, passing the partial sum to the PE below.
- **`accumulator.sv`** (+ `fifo.sv`) — the MMU's output columns finish at
  different cycles (column *j* finishes `N-1-j` cycles after column 0); this
  module de-skews them back into whole rows using one FIFO per column.
- **`bias.sv` → `activation.sv`** — per-column bias add, then ReLU. This is
  the last stage before the result goes back to the sequencer for
  transmission.

`rtl/weight_loader.sv` is **not** part of this pipeline yet — it's a
ROM-driven ($readmemh) weight-tile loader intended for the planned DE1-SoC
target (`README.md` §3.2), not something `tpu_top.sv` instantiates today.
`fpga/pico2_ice/Makefile`'s RTL file list is the authoritative statement of
what's actually synthesized for this board.

### 2.2 Two board-specific quirks baked into the RTL/build

- **The clock is not a crystal.** `clk` (iCE40 package pin 35) is driven by
  the RP2350's `GPOUT0` clock-output feature over a board trace, at
  whatever frequency `ice_fpga_init()` requests in firmware — see §4 and
  §8.1. The synthesis-time `CLK_FREQ` parameter (`fpga/pico2_ice/Makefile`,
  default 12 MHz) sets the UART baud divider computed inside
  `uart_rx.sv`/`uart_tx.sv`, so it must always match what the firmware
  actually requests, or you get garbled UART bytes with no other symptom.
- **Power-on-reset generator in `tpu_top.sv`.** `reset_n` on this board is a
  push-button with a plain external pull-up and no reset IC, so it reads
  idle-high the instant the FPGA configures — the synchronous `if (reset)`
  branch in every module would otherwise never fire once. `tpu_top.sv`
  therefore has an internal 256-cycle power-on counter OR'd into the
  datapath reset (`rst = ~reset_n | ~por_done`), so every register gets a
  known-good value at least once regardless of the button's level. This was
  a real hardware bug found during bring-up (§8.4), not a
  defensive-programming nicety — keep it when refactoring `tpu_top.sv`.

## 3. Communication: host ⇄ RP2350 ⇄ FPGA

```
PC (tpu_host.py) --USB-CDC "iCE40 UART"--> RP2350 uart0 (GPIO28/29) --wire--> iCE40 pins 9/11 (rx_pin/tx_pin)
```

The RP2350 firmware forwards its `uart0` hardware peripheral straight
through to USB-CDC (`ICE_USB_UART0_CDC` in `tusb_config.h`); it does not
parse or interpret the bytes. All protocol logic lives in
`tpu_sequencer.sv` on the FPGA side and its mirror in `tpu_host.py` on the PC
side.

Wire protocol (8-N-1, 115 200 baud on the USB-CDC side; the FPGA-side UART
runs at whatever `BAUD_RATE`/`CLK_FREQ` the bitstream was synthesized with):

```
Host -> FPGA:  [CMD][LEN][payload[LEN]]
FPGA -> Host:  [STATUS][LEN][payload[LEN]]     (STATUS: 0xAA=OK, 0xFF=ERR)

0x01 LOAD_WEIGHTS  LEN=4  [w10,w11,w00,w01]  int8, bottom row first
0x02 LOAD_BIAS     LEN=4  [b0_lo,b0_hi,b1_lo,b1_hi]  int16 LE
0x03 LOAD_ACT      LEN=4  [a00,a01,a10,a11]  int8, row-major
0x04 RUN           LEN=0  -> [r0c0,r0c1,r1c0,r1c1] int16 LE (8 bytes)
0x05 RESET         LEN=0
```

`RUN` executes `Y = ReLU(A @ W + bias)` on-chip and returns the 2x2 result.
`tpu_sequencer.sv`'s header comment is the authoritative protocol definition
(useful if you ever drive the board directly — a terminal program, a
different language — instead of through the Python driver); see
`docs/sequencer_uart_design.md` for the full FSM/timing writeup.
`tpu_host.py` (repo root) is the Python implementation of the host side (`TPU`
class: `load_weights`, `load_bias`, `load_activations`, `run`, `reset`, plus a
`matmul()` convenience wrapper and a CLI with `--selftest`/`--weights`/
`--activations`/`--bias`/`--reset`). `tests/hw_regression.py` drives the same
protocol for a broader real-hardware regression (replays every
`tpu_sequencer_tb.sv` case plus int8/int16 boundary and randomized-stress
cases).

## 4. `firmware/pico2_ice_bridge/` explained

A small fork of `pico-ice-sdk/examples/rp2_usb_uart`, kept minimal on
purpose — its only job is USB↔UART bridging, FPGA clock/config, and reporting
FPGA config status on the LED.

- **`main.c`** — the whole program:
  - `uart_init(uart0, 115200)` + `gpio_set_function()` on **GPIO28/29** for
    the FPGA-facing UART. These pins matter: the upstream example this was
    forked from hardcodes GPIO0/GPIO1, which are correct on the original
    RP2040-based pico-ice but are wired to the onboard LEDs (not the FPGA)
    on pico2-ice — see §8.2.
  - `ice_usb_init()` — brings up the USB composite device described in
    `usb_descriptors.c` (two CDC ports + a DFU interface).
  - `ice_fpga_init(FPGA_DATA, AS_MHZ(12))` — exports a 12 MHz clock to the
    FPGA over `GPOUT0`, instead of the SDK's 48 MHz default. This **must**
    stay numerically in sync with `fpga/pico2_ice/Makefile`'s `CLK_FREQ`;
    it's the single most common source of "board looks alive but nothing
    responds correctly" bugs if the two drift apart (§8.1).
  - `ice_fpga_configured(FPGA_DATA)` → drives the onboard LED
    green/red. This function exists in `pico-ice-sdk/src/ice_fpga.c` but
    isn't declared in the public header or used by any upstream example —
    it's the only call that actually polls `CDONE`; the SDK's own DFU
    manifest-complete callback in `ice_usb.c` reports a bogus "firmware
    corrupt" error on every flash (a falsy-zero-return bug in
    `ice_fpga_start()`), so this LED check is the real signal, not that
    message (§8.3).
- **`usb_descriptors.c`** — TinyUSB descriptor tables: two CDC ACM
  interfaces (`"RP2040 logs"` and `"iCE40 UART"` — the second one is what
  `tpu_host.py --port` should point at) plus a DFU interface with two alt
  settings (`"iCE40 DFU (Flash)"` / `"iCE40 DFU (CRAM)"`), used by
  `dfu-util`/`make prog` to push the FPGA bitstream.
- **`tusb_config.h`** — TinyUSB device-stack configuration: enables 2×CDC +
  1×DFU (with 2 alt settings), sets buffer sizes, and sets
  `ICE_USB_UART0_CDC=1` (the flag that makes `ice_usb_init()` bridge
  `uart0` to the second CDC port automatically).
- **`CMakeLists.txt`** — points `PICO_ICE_SDK_PATH` two directories up at the
  vendored (gitignored) `pico-ice-sdk/` clone at the repo root, imports
  `pico-sdk` from inside that SDK checkout, and links `pico_ice_sdk` +
  `pico_ice_usb` into the `pico2_ice_bridge` executable built from `main.c`
  + `usb_descriptors.c`.
- **`pico_sdk_import.cmake`** — the standard boilerplate `pico-sdk` cmake
  import shim (unmodified from the SDK template).
- **`.gitignore`** — ignores `build/`, the out-of-tree cmake/ninja build
  directory that produces the `.uf2`.

## 5. `fpga/pico2_ice/` explained

- **`Makefile`** — the yosys → nextpnr-ice40 → icepack build for this board:
  - `make` → synthesizes `$(RTL)` (the explicit file list at the top,
    currently 13 files ending in `tpu_top.sv`) with `synth_ice40`, sets the
    `CLK_FREQ` chparam, place-and-routes with `nextpnr-ice40 --up5k --package
    sg48` against `tpu_top.pcf`, and packs the final `.bin` bitstream with
    `icepack`.
  - `make time` → static timing (`icetime`) report against `.asc`; useful for
    checking margin against the board's measured ~32 MHz fMax whenever you
    change the datapath. If it fails with `Can't find chipdb file for device
    5k` (a Homebrew/icestorm path-resolution quirk, not an RTL issue), pass
    the chipdb explicitly:
    ```bash
    make time ICETIME_CHIPDB=$(brew --prefix icestorm)/share/icestorm/chipdb/chipdb-5k.txt
    ```
  - `make prog` → `dfu-util -d 1209:b1c0 -a 0 -D tpu_top.bin -R`, flashing
    over the DFU "Flash" alt-interface the firmware exposes.
  - `make clean` → removes `.json`/`.asc`/`.bin`.
  - `CLK_FREQ` (env/make override, default 12 000 000) is the single knob
    that must match `firmware/pico2_ice_bridge/main.c`'s
    `ice_fpga_init(FPGA_DATA, AS_MHZ(12))` call.
- **`tpu_top.pcf`** — pin constraints, iCE40 package-pin namespace (**not**
  the RP2350 GPIO namespace used in firmware):
  - `clk` → pin 35 (the `GPOUT0`-driven clock, not a crystal — see §2.2)
  - `reset_n` → pin 10, active-low, `-pullup yes` (belt-and-suspenders; a
    real 10K pull-up, R21, already exists on the board)
  - `rx_pin` → pin 9, `tx_pin` → pin 11 (`DEFAULT_UART_RX`/`DEFAULT_UART_TX`
    in the vendor's own `pico-ice-sdk/rtl/pico2_ice.pcf` reference file —
    these are the same physical pins the RP2350 firmware bridges to
    GPIO28/29)
- Build artifacts (`tpu_top.json`, `.asc`, `.bin`) land in this same
  directory and are gitignored.

## 6. Prerequisites

```bash
brew install yosys nextpnr-ice40 icestorm dfu-util cmake ninja   # macOS
# sudo apt install yosys nextpnr-ice40 icestorm dfu-util cmake ninja   # Debian/Ubuntu
```

RP2350 firmware needs a C cross-compiler for either its ARM (Cortex-M33) or
RISC-V (Hazard3) core. This repo's firmware was built and tested with a
RISC-V toolchain (`riscv64-unknown-elf-gcc`, must support the `rv32imac`
multilib); an ARM `arm-none-eabi-gcc` toolchain works too with different
cmake flags (see §7.2).

Python side (`tpu_host.py`) — this repo's venv lives at the repo root:

```bash
source bin/activate   # or create one: python3 -m venv <dir> && source <dir>/bin/activate
pip install -r requirements.txt   # pyserial, numpy
```

### 6.1 Cleaning up / recreating the venv

Because this venv is created directly in the repo root (`python3 -m venv .`,
not in a subdirectory like `.venv/`), it leaves these behind there: `bin/`,
`include/`, `lib/`, `pyvenv.cfg`, plus `__pycache__/` wherever a `.py` file
has actually been imported (repo root, `tests/`). All of them are gitignored
and safe to delete — nothing under them is tracked. To wipe and recreate
from scratch (e.g. a corrupted install, or picking up a new Python version):

```bash
deactivate 2>/dev/null                                   # if currently active
rm -rf bin include lib pyvenv.cfg __pycache__ tests/__pycache__
python3 -m venv .
source bin/activate
pip install -r requirements.txt
```

**Gotcha**: `python3 -m venv <target>` always (re)writes a `.gitignore` file
inside `<target>`, containing just `*`. Since this venv's target is the repo
root itself, every time step 3 runs it **overwrites the repo's real
`.gitignore`** (the one with the `sim/`, `fpga/**/*.bin`, `bin/`/`include/`/
`lib/`/`pyvenv.cfg`/`__pycache__/`, and `pico-ice-sdk/` rules) with that
one-line blanket ignore — which silently hides the *entire* repo from `git
status`/`git add` until fixed. After recreating the venv, always check:

```bash
git diff .gitignore
```

and restore it if it got clobbered (`git checkout -- .gitignore` if you have
no other pending edits there). Creating the venv in its own subdirectory
instead (`python3 -m venv .venv && source .venv/bin/activate`, adjusting
`requirements.txt`'s consumers accordingly) avoids this failure mode
entirely, since venv's auto-generated `.gitignore` would then land inside
`.venv/` instead of at the repo root.

`pico-ice-sdk/` must be cloned into the repo root (it's gitignored — vendored,
not tracked) with its submodules initialized:

```bash
cd pico-ice-sdk
git submodule update --init --recursive
```

## 7. Build, flash, and validate

Day-to-day iteration on `rtl/*.sv` follows this loop; §7.1–§7.5 below spell
out each step in full.

```bash
make test                                    # repo root: simulate first
cd fpga/pico2_ice && make && make prog       # build + flash gateware
python3 ../../tpu_host.py --port /dev/cu.usbmodemN --selftest
```

You only need to touch `firmware/pico2_ice_bridge/` (§7.2, §7.3) if you
change `CLK_FREQ`, the UART pins, or anything else about the RP2350 side —
pure datapath/RTL changes never require a firmware rebuild, just a gateware
rebuild + reflash.

### 7.1 Simulate first

```bash
make test                # repo root: build + run all 18 testbenches
make test-tpu_sequencer  # or just the one(s) touching your change
```

Every RTL change should pass simulation before it ever touches hardware —
the testbenches are what caught every functional bug so far, and they're
much faster to iterate on than a synthesis+PnR+flash cycle.

### 7.2 Build the FPGA gateware

```bash
cd fpga/pico2_ice
make            # -> tpu_top.bin
make time       # optional: static timing report (fMax)
make clean
```

`CLK_FREQ` defaults to 12 MHz (override with `make CLK_FREQ=...`). This is
**not** a board constant — see §8.1. It must match whatever the RP2350
firmware actually exports.

### 7.3 Build the RP2350 firmware

Only needed the first time, or after a change to `firmware/pico2_ice_bridge/`
itself (e.g. `CLK_FREQ`/pin changes):

```bash
cd firmware/pico2_ice_bridge
mkdir -p build && cd build
cmake -DPICO_BOARD=pico2_ice -DPICO_PLATFORM=rp2350-riscv \
      -DPICO_GCC_TRIPLE=riscv64-unknown-elf -G Ninja ..
ninja           # -> pico2_ice_bridge.uf2
```

For the ARM core instead: `-DPICO_PLATFORM=rp2350-arm-s` (drop
`-DPICO_GCC_TRIPLE`), with `arm-none-eabi-gcc` on `PATH`.

First configure downloads and builds `picotool` from source (needed for the
`.uf2` post-processing step) — expect this only on a clean `build/`
directory.

### 7.4 Flash both images

**Order matters**: firmware first, then gateware — `dfu-util` needs the
firmware's DFU USB interface already running before it can push a bitstream.

1. **Firmware**: hold **BOOTSEL**, plug in USB (or hold BOOTSEL + press reset
   if already plugged in). The board mounts as a USB drive. Drag
   `firmware/pico2_ice_bridge/build/pico2_ice_bridge.uf2` onto it. It
   unmounts and reboots automatically.

2. **Check the LED**: green = FPGA configured successfully (a real `CDONE`
   check, see §8.3); red = it didn't. Consult §8 below if red.

3. **Gateware**:
   ```bash
   cd fpga/pico2_ice
   make prog
   ```
   This runs `dfu-util -d 1209:b1c0 -a 0 -D tpu_top.bin -R`. Ignore the
   `Device's firmware is corrupt` message — see §8.3, it's a known false
   alarm.

4. Power-cycle or unplug/replug USB so the RP2350 re-runs its boot-time
   `CDONE` check against the bitstream you just flashed, and re-check the
   LED.

### 7.5 Validate

Find the board's two USB-CDC ports:

```bash
python3 -c "import serial.tools.list_ports as p; [print(x) for x in p.comports()]"
```

Both may show identically (e.g. `pico-ice` on macOS/pyserial) — there's no
reliable cross-platform way to tell them apart from the port list alone
(§8.5). Try the higher-numbered `/dev/cu.usbmodemN` first; if it doesn't
respond, try the other one.

```bash
python3 tpu_host.py --port /dev/cu.usbmodemN --selftest
```

Expected output:

```
Sending W=[[4, 5], [2, 3]] A=[[1, 2], [3, 4]] bias=[100, 200]
Got:      [[108, 211], [120, 227]]
Expected: [[108, 211], [120, 227]]
PASS -- hardware datapath matches simulation golden values
```

This replays the exact vector from `tests/tpu_sequencer_tb.sv` Test 1 — a
pass here means the *entire* pipeline (UART RX → sequencer → weight FIFO →
unified buffer → systolic data setup → MMU → accumulator → bias → ReLU →
UART TX) matches simulation, on real silicon.

For manual/custom matrices:

```bash
python3 tpu_host.py --port /dev/cu.usbmodemN \
    --weights 4,5,2,3 --activations 1,2,3,4 --bias 100,200
```

For a broader hardware regression than the single self-test vector —
replays every case `tests/tpu_sequencer_tb.sv` covers in simulation (zero
weights, negative-arithmetic ReLU clamp, identity matrix, RESET round-trip,
unknown-CMD error path), plus int8/int16 boundary cases and a randomized
stress run:

```bash
python3 tests/hw_regression.py --port /dev/cu.usbmodemN
# or:
make hw-test PORT=/dev/cu.usbmodemN
```

`dfu-util -l` is a useful sanity check at any point — it should list two DFU
alt interfaces (`iCE40 DFU (Flash)` / `iCE40 DFU (CRAM)`) if the firmware is
running and enumerated correctly, independent of whether the FPGA side
works.

If a change ever needs a different `CLK_FREQ` (e.g. a bigger array that
lowers fMax), update it in **two** places together:
`fpga/pico2_ice/Makefile`'s `CLK_FREQ` and
`firmware/pico2_ice_bridge/main.c`'s `AS_MHZ(...)` argument — then rebuild
and reflash *both* images, since a mismatch only shows up as garbled UART
bytes, not an obvious failure (§8.1).

## 8. Known gotchas (found the hard way — read before debugging blind)

### 8.1 The FPGA clock is not a fixed crystal

`clk` (iCE40 pin 35) is driven by the RP2350's `GPOUT0` clock-output feature
over a board trace (`pico-ice-sdk/include/ice_fpga.h`), not a dedicated
oscillator. The actual frequency is whatever `ice_fpga_init(FPGA_DATA,
freq_hz)` requests in firmware. `tpu_top`'s measured fMax on the UP5K is ~32
MHz, so `firmware/pico2_ice_bridge/main.c` requests 12 MHz (`AS_MHZ(12)`)
rather than the SDK's 48 MHz default — that must stay in sync with
`fpga/pico2_ice/Makefile`'s `CLK_FREQ`, since it sets the UART baud-rate
divider computed at synthesis time. Mismatch symptom: garbled bytes, not
silence.

### 8.2 RP2350 GPIO0/GPIO1 are the onboard LED, not the FPGA UART

`pico-ice-sdk/examples/rp2_usb_uart` (the upstream example our firmware
forks) hardcodes `UART_TX_PIN=0`/`UART_RX_PIN=1`. That's correct for the
original pico-ice (RP2040) but wrong on pico2-ice — confirmed directly
against the board schematic (`tinyvision-ai-inc/pico2-ice` repo,
`Board/Rev1/pico2-ice.pdf`): GPIO0/GPIO1 there are wired to `LED_G`/`LED_R`.
The real wires to the iCE40's UART pins (package pins 9/11,
`DEFAULT_UART_RX`/`DEFAULT_UART_TX`) are **GPIO28/GPIO29** — confirmed both
in the schematic's RP2350 pin table and against the RP2350 datasheet
(GPIO28 = UART0 TX, GPIO29 = UART0 RX). `firmware/pico2_ice_bridge/main.c`
uses the corrected pins; if you fork it again, don't copy the upstream
example's pin numbers verbatim. Symptom of the wrong pins: total silence on
both USB-CDC ports, no matter what you send.

### 8.3 The DFU "firmware corrupt" message is a known false alarm

`dfu-util` reports `Device's firmware is corrupt. It cannot return to
run-time (non-DFU) operations` on **every** gateware flash, success or
failure. Traced to `pico-ice-sdk/src/ice_usb.c`'s DFU manifest callback: it
does `ok = ice_fpga_start(FPGA_DATA)` and reports that error whenever `ok` is
falsy — but `ice_fpga_start()` unconditionally `return 0;` (never actually
polls `CDONE`), and `0` is falsy in C. Don't trust this message either way.
`firmware/pico2_ice_bridge/main.c` adds a real check instead, via
`ice_fpga_configured()` — a function that exists in
`pico-ice-sdk/src/ice_fpga.c` but isn't declared in the public header or
called by any upstream example — shown on the onboard LED (green =
configured, red = not).

### 8.4 No power-on-reset generator meant `uart_tx` powered up stuck

The actual root-cause bug, and a real RTL fix (`rtl/tpu_top.sv`), not a
board-specific workaround: every module's registers (e.g. `uart_tx.sv`'s
`tx_busy`/`state`) only get a known-good value inside their synchronous `if
(reset)` branch. On this board, `reset_n` (the push-button, with a real
external 10K pull-up already on the board, `R21`) reads idle-high from the
instant the FPGA configures — there's no reset IC forcing a pulse — so that
branch never fired even once. Registers were left to whatever value the
toolchain's power-on initial-value inference happened to produce, and
`uart_tx` powered up with `tx_busy` stuck, transmitting nothing, forever.
Simulation never caught this because every testbench explicitly pulses
`reset` for a few cycles at the start. Fixed with an internal
power-on-reset counter in `tpu_top.sv`, OR'd into `rst`, so the reset branch
always fires at least once regardless of `reset_n`'s level at configuration
time. This class of bug is generally worth guarding against on any target,
not just this board.

**Debugging path that found this** (useful if something regresses): built a
series of minimal bitstreams to bisect the failure — a bare combinational
echo (`tx_pin = rx_pin`, no clock at all) to test the physical UART wiring
in isolation; a free-running counter using the iCE40's internal `SB_HFOSC`
oscillator (no dependency on the external `clk` pin) to test whether the
fabric ran sequential logic at all; a version of that gated on `reset_n`'s
raw level to test the reset signal specifically; and finally the real
`uart_tx.sv` module driven both with and without a reset dependency, which
isolated the bug to that module's missing power-on state. Each of these
narrowed the search by ruling out one subsystem at a time (physical wiring →
clock delivery → reset generation) rather than guessing at the full design.

### 8.5 Both USB-CDC ports can look identical

macOS/pyserial's `list_ports.comports()` shows the USB product string
(`pico-ice`) for both CDC interfaces, not the per-interface description
(`RP2040 logs` vs `iCE40 UART` from
`firmware/pico2_ice_bridge/usb_descriptors.c`). No reliable way found to
disambiguate from the port list alone; §7.5 covers the trial-and-error
approach.

## 9. Where to look next

- `docs/sequencer_uart_design.md` — `tpu_sequencer`/`uart_rx`/`uart_tx` FSM
  design and cycle-by-cycle timing.
- `README.md` — overall project status, simulation workflow (`make test`),
  and the planned DE1-SoC (Cyclone V) target.
