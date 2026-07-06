# Getting `tpu_top` running on the pico2-ice

End-to-end process for building, flashing, and validating the TPU design on a
[pico2-ice](https://pico2-ice.tinyvision.ai/) board (RP2350 + iCE40UP5K). Covers the
open-source toolchain path (yosys/nextpnr-ice40/icepack), not Quartus/DE1-SoC.

Two independent images have to be on the board at once:

- **FPGA gateware** (`fpga/pico2_ice/tpu_top.bin`) — the TPU design itself, built from
  `rtl/*.sv`.
- **RP2350 firmware** (`firmware/pico2_ice_bridge/build/pico2_ice_bridge.uf2`) — bridges a
  USB-CDC serial port to the FPGA's UART pins and tells the FPGA what clock frequency to run
  at. Without the right firmware running, `dfu-util` has nothing to talk to and the FPGA
  never receives a clock.

## 1. Prerequisites

```bash
brew install yosys nextpnr-ice40 icestorm dfu-util cmake ninja   # macOS
# sudo apt install yosys nextpnr-ice40 icestorm dfu-util cmake ninja   # Debian/Ubuntu
```

RP2350 firmware needs a C cross-compiler for either its ARM (Cortex-M33) or RISC-V
(Hazard3) core. This repo's firmware was built and tested with a RISC-V toolchain
(`riscv64-unknown-elf-gcc`, must support the `rv32imac` multilib); an ARM
`arm-none-eabi-gcc` toolchain works too with different cmake flags (see §3).

Python side (`tpu_host.py`) — this repo's venv lives at the repo root:

```bash
source bin/activate   # or create one: python3 -m venv <dir> && source <dir>/bin/activate
pip install -r requirements.txt   # pyserial, numpy
```

`pico-ice-sdk/` must be cloned into the repo root (it's gitignored — vendored, not
tracked) with its submodules initialized:

```bash
cd pico-ice-sdk
git submodule update --init --recursive
```

## 2. Build the FPGA gateware

```bash
cd fpga/pico2_ice
make            # -> tpu_top.bin
make time       # optional: static timing report (fMax)
make clean
```

`CLK_FREQ` defaults to 12 MHz (override with `make CLK_FREQ=...`). This is **not** a
board constant — see §6.1. It must match whatever the RP2350 firmware actually exports.

If `make time` fails with `Can't find chipdb file for device 5k` (a Homebrew/icestorm
path-resolution quirk, not an RTL issue), pass the chipdb explicitly:

```bash
make time ICETIME_CHIPDB=$(brew --prefix icestorm)/share/icestorm/chipdb/chipdb-5k.txt
```

## 3. Build the RP2350 firmware

```bash
cd firmware/pico2_ice_bridge
mkdir -p build && cd build
cmake -DPICO_BOARD=pico2_ice -DPICO_PLATFORM=rp2350-riscv \
      -DPICO_GCC_TRIPLE=riscv64-unknown-elf -G Ninja ..
ninja           # -> pico2_ice_bridge.uf2
```

For the ARM core instead: `-DPICO_PLATFORM=rp2350-arm-s` (drop `-DPICO_GCC_TRIPLE`), with
`arm-none-eabi-gcc` on `PATH`.

First configure downloads and builds `picotool` from source (needed for the `.uf2`
post-processing step) — expect this only on a clean `build/` directory.

## 4. Flash both images

**Order matters**: firmware first, then gateware — `dfu-util` needs the firmware's DFU
USB interface already running before it can push a bitstream.

1. **Firmware**: hold **BOOTSEL**, plug in USB (or hold BOOTSEL + press reset if already
   plugged in). The board mounts as a USB drive. Drag
   `firmware/pico2_ice_bridge/build/pico2_ice_bridge.uf2` onto it. It unmounts and reboots
   automatically.

2. **Check the LED**: green = FPGA configured successfully (a real `CDONE` check, see
   §6.3); red = it didn't. Reflect on §6 below if red.

3. **Gateware**:
   ```bash
   cd fpga/pico2_ice
   make prog
   ```
   This runs `dfu-util -d 1209:b1c0 -a 0 -D tpu_top.bin -R`. Ignore the
   `Device's firmware is corrupt` message — see §6.2, it's a known false alarm.

4. Power-cycle or unplug/replug USB so the RP2350 re-runs its boot-time CDONE check
   against the bitstream you just flashed, and re-check the LED.

## 5. Validate

Find the board's two USB-CDC ports:

```bash
python3 -c "import serial.tools.list_ports as p; [print(x) for x in p.comports()]"
```

Both may show identically (e.g. `pico-ice` on macOS/pyserial) — there's no reliable
cross-platform way to tell them apart from the port list alone. Try the higher-numbered
`/dev/cu.usbmodemN` first; if it doesn't respond, try the other one.

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

This replays the exact vector from `tests/tpu_sequencer_tb.sv` Test 1 — a pass here means
the *entire* pipeline (UART RX → sequencer → weight FIFO → unified buffer → systolic data
setup → MMU → accumulator → bias → ReLU → UART TX) matches simulation, on real silicon.

For manual/custom matrices:

```bash
python3 tpu_host.py --port /dev/cu.usbmodemN \
    --weights 4,5,2,3 --activations 1,2,3,4 --bias 100,200
```

`dfu-util -l` is a useful sanity check at any point — it should list two DFU alt
interfaces (`iCE40 DFU (Flash)` / `iCE40 DFU (CRAM)`) if the firmware is running and
enumerated correctly, independent of whether the FPGA side works.

## 6. Known gotchas (found the hard way — read before debugging blind)

### 6.1 The FPGA clock is not a fixed crystal

`clk` (iCE40 pin 35) is driven by the RP2350's `GPOUT0` clock-output feature over a board
trace (`pico-ice-sdk/include/ice_fpga.h`), not a dedicated oscillator. The actual frequency
is whatever `ice_fpga_init(FPGA_DATA, freq_hz)` requests in firmware. `tpu_top`'s measured
fMax on the UP5K is ~32 MHz, so `firmware/pico2_ice_bridge/main.c` requests 12 MHz
(`AS_MHZ(12)`) rather than the SDK's 48 MHz default — that must stay in sync with
`fpga/pico2_ice/Makefile`'s `CLK_FREQ`, since it sets the UART baud-rate divider computed
at synthesis time. Mismatch symptom: garbled bytes, not silence.

### 6.2 RP2350 GPIO0/GPIO1 are the onboard LED, not the FPGA UART

`pico-ice-sdk/examples/rp2_usb_uart` (the upstream example our firmware forks) hardcodes
`UART_TX_PIN=0`/`UART_RX_PIN=1`. That's correct for the original pico-ice (RP2040) but
wrong on pico2-ice — confirmed directly against the board schematic
(`tinyvision-ai-inc/pico2-ice` repo, `Board/Rev1/pico2-ice.pdf`): GPIO0/GPIO1 there are
wired to `LED_G`/`LED_R`. The real wires to the iCE40's UART pins (package pins 9/11,
`DEFAULT_UART_RX`/`DEFAULT_UART_TX`) are **GPIO28/GPIO29** — confirmed both in the
schematic's RP2350 pin table and against the RP2350 datasheet (GPIO28 = UART0 TX, GPIO29 =
UART0 RX). `firmware/pico2_ice_bridge/main.c` uses the corrected pins; if you fork it
again, don't copy the upstream example's pin numbers verbatim. Symptom of the wrong pins:
total silence on both USB-CDC ports, no matter what you send.

### 6.3 The DFU "firmware corrupt" message is a known false alarm

`dfu-util` reports `Device's firmware is corrupt. It cannot return to run-time (non-DFU)
operations` on **every** gateware flash, success or failure. Traced to
`pico-ice-sdk/src/ice_usb.c`'s DFU manifest callback: it does
`ok = ice_fpga_start(FPGA_DATA)` and reports that error whenever `ok` is falsy — but
`ice_fpga_start()` unconditionally `return 0;` (never actually polls `CDONE`), and `0` is
falsy in C. Don't trust this message either way. `firmware/pico2_ice_bridge/main.c` adds a
real check instead, via `ice_fpga_configured()` — a function that exists in
`pico-ice-sdk/src/ice_fpga.c` but isn't declared in the public header or called by any
upstream example — shown on the onboard LED (green = configured, red = not).

### 6.4 No power-on-reset generator meant `uart_tx` powered up stuck

The actual root-cause bug, and a real RTL fix (`rtl/tpu_top.sv`), not a board-specific
workaround: every module's registers (e.g. `uart_tx.sv`'s `tx_busy`/`state`) only get a
known-good value inside their synchronous `if (reset)` branch. On this board, `reset_n`
(the push-button, with a real external 10K pull-up already on the board, `R21`) reads
idle-high from the instant the FPGA configures — there's no reset IC forcing a pulse — so
that branch never fired even once. Registers were left to whatever value the toolchain's
power-on initial-value inference happened to produce, and `uart_tx` powered up with
`tx_busy` stuck, transmitting nothing, forever. Simulation never caught this because every
testbench explicitly pulses `reset` for a few cycles at the start. Fixed with an internal
power-on-reset counter in `tpu_top.sv`, OR'd into `rst`, so the reset branch always fires
at least once regardless of `reset_n`'s level at configuration time. This class of bug is
generally worth guarding against on any target, not just this board.

**Debugging path that found this** (useful if something regresses): built a series of
minimal bitstreams to bisect the failure — a bare combinational echo (`tx_pin = rx_pin`,
no clock at all) to test the physical UART wiring in isolation; a free-running counter
using the iCE40's internal `SB_HFOSC` oscillator (no dependency on the external `clk` pin)
to test whether the fabric ran sequential logic at all; a version of that gated on
`reset_n`'s raw level to test the reset signal specifically; and finally the real
`uart_tx.sv` module driven both with and without a reset dependency, which isolated the bug
to that module's missing power-on state. Each of these narrowed the search by ruling out
one subsystem at a time (physical wiring → clock delivery → reset generation) rather than
guessing at the full design.

### 6.5 Both USB-CDC ports can look identical

macOS/pyserial's `list_ports.comports()` shows the USB product string (`pico-ice`) for
both CDC interfaces, not the per-interface description (`RP2040 logs` vs `iCE40 UART`
from `firmware/pico2_ice_bridge/usb_descriptors.c`). No reliable way found to disambiguate
from the port list alone; §5 covers the trial-and-error approach.

## 7. Protocol reference

`tpu_host.py` implements the wire protocol from `rtl/tpu_sequencer.sv`, summarized here for
anyone driving it directly (a terminal program, a different language, etc.) instead of
through the Python driver:

```
Host -> FPGA:  [CMD][LEN][payload[LEN]]
FPGA -> Host:  [STATUS][LEN][payload[LEN]]     (STATUS: 0xAA=OK, 0xFF=ERR)

0x01 LOAD_WEIGHTS  LEN=4  [w10,w11,w00,w01]  int8, bottom row first
0x02 LOAD_BIAS     LEN=4  [b0_lo,b0_hi,b1_lo,b1_hi]  int16 LE
0x03 LOAD_ACT      LEN=4  [a00,a01,a10,a11]  int8, row-major
0x04 RUN           LEN=0  -> [r0c0,r0c1,r1c0,r1c1] int16 LE (8 bytes)
0x05 RESET         LEN=0
```

`RUN` executes `Y = ReLU(A @ W + bias)` on-chip and returns the 2x2 result. See
`docs/sequencer_uart_design.md` for the full FSM/timing writeup, and
`rtl/tpu_sequencer.sv`'s header comment for the authoritative protocol definition.
