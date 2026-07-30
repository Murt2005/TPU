# pico2-ice (iCE40UP5K) target

Reference for the primary, hardware-validated target. The root
[`README.md`](../README.md) §1 is the quick start and §1.8 the short
troubleshooting table; this page is what you read when those aren't enough.

## 1. Two chips, two images, one order

pico2-ice carries two programmable chips, and each needs its own image:

| Chip | Role | Image | Built from |
|---|---|---|---|
| Lattice iCE40UP5K | Runs the TPU datapath | `fpga/ice40/tpu_top.bin` | `rtl/*.sv` |
| Raspberry Pi RP2350 | USB bridge **+ FPGA clock + bitstream loader** | `firmware/build*/pico2_ice_bridge.uf2` | `firmware/*` |

The RP2350 is not just a USB-to-serial chip. It **drives the FPGA's clock and
loads its bitstream**, so its firmware must be running correctly before the
FPGA can do anything at all: no firmware means no clock, no `CDONE`, and
nothing listening on the DFU interface `dfu-util` needs.

**Flash firmware first, gateware second.** Always.

## 2. Build knobs (`fpga/ice40/Makefile`)

| Knob | Default | Notes |
|---|---|---|
| `CLK_FREQ` | `12000000` | **Must match** `firmware/main.c`'s `ice_fpga_init()` request. 24 MHz for SPI builds |
| `BAUD_RATE` | `1000000` | UART builds only. 1 M divides 12 MHz exactly (`TICKS_PER_BIT=12`, zero error). Fallback 921600 (+0.16%) |
| `ARRAY_ROWS` / `NUM_COLS` / `M_TILE` | `2` / `2` / `=ARRAY_ROWS` | Array shape; must match the host's `--rows/--cols/--m-tile` |
| `USE_SPI` | `0` | `1` = `spi_slave.sv` on the config bus; needs `TPU_LINK_SPI` firmware |
| `USE_MAC16_PAIR` | `0` | `1` = `pe_pair.sv`, two PEs per `SB_MAC16`. Requires even `ARRAY_ROWS`. Drops `-dsp` (nothing left to infer, and it must not remap hand-placed primitives) |
| `ABC_FLAGS` | `-abc9 -dff` | Register-aware ABC pass; worth ~412 LCs on the 4×4 build |
| `DSP_FLAG` | `-dsp` unless pairing | Maps `pe.sv` multiplies to `SB_MAC16` (~251 → 36 LUT/PE) |

Targets: `json` (synth) · `asc` (P&R) · `bin` (pack) · `stat` (yosys cell
counts) · `util` (nextpnr utilisation) · `time` (icetime fMax) · `prog` (DFU
flash) · `clean`.

If `make time` fails with `Can't find chipdb file for device 5k` — a Homebrew
path quirk, not an RTL problem:

```bash
make time ICETIME_CHIPDB=$(brew --prefix icestorm)/share/icestorm/chipdb/chipdb-5k.txt
```

## 3. The clock/baud coupling

This is the single most common source of "board looks alive but nothing
responds correctly."

`clk` (iCE40 pin 35) is **not a crystal** — it's driven by the RP2350's
`GPOUT0` clock output over a board trace, at whatever `ice_fpga_init()`
requests. The UART baud divider is computed at *synthesis* time from
`CLK_FREQ`/`BAUD_RATE`. So three numbers must agree:

```
firmware/main.c   ice_fpga_init(FPGA_DATA, AS_MHZ(12))
fpga/ice40/Makefile   CLK_FREQ = 12000000
tpu_host.py       DEFAULT_BAUD (matches BAUD_RATE)
```

Symptom of a mismatch: **garbled bytes, not silence.**

Measured fMax is ~28–32 MHz depending on shape, so 12 MHz leaves ~2.6×
margin. SPI builds run the core at 24 MHz — the baud divider was the 12 MHz
constraint, and `spi_slave` has no such coupling.

## 4. Pin constraints (`fpga/ice40/tpu_top.pcf`)

iCE40 **package-pin** namespace — not the RP2350 GPIO namespace used in
firmware. Easy to conflate; don't.

| Signal | Pin | Note |
|---|---|---|
| `clk` | 35 | `GPOUT0`-driven, see §3 |
| `reset_n` | 10 | active-low, `-pullup yes`; a real 10K pull-up (R21) already exists |
| `rx_pin` | 9 | vendor's `DEFAULT_UART_RX` |
| `tx_pin` | 11 | vendor's `DEFAULT_UART_TX` |

Pins 9/11 are the same physical wires the firmware bridges to RP2350
GPIO28/29.

## 5. Gotchas — read before debugging blind

### 5.1 The DFU "firmware corrupt" message is a false alarm

`dfu-util` reports `Device's firmware is corrupt. It cannot return to
run-time (non-DFU) operations` on **every** gateware flash, success or
failure. Root cause: `pico-ice-sdk/src/ice_usb.c`'s DFU manifest callback
does `ok = ice_fpga_start(FPGA_DATA)` and errors whenever `ok` is falsy — but
`ice_fpga_start()` unconditionally `return 0;` and never polls `CDONE`.

Don't trust that message in either direction. `firmware/main.c` adds a real
check via `ice_fpga_configured()` — a function that exists in the SDK source
but is not declared in the public header or called by any upstream example —
and shows it on the LED: **green = configured, red = not**.

### 5.2 RP2350 GPIO0/GPIO1 are the LED, not the FPGA UART

The upstream `rp2_usb_uart` example hardcodes `UART_TX_PIN=0`/`RX_PIN=1`.
Correct on the RP2040-based pico-ice; **wrong** on pico2-ice, where GPIO0/1
are wired to `LED_G`/`LED_R`. The real wires to the iCE40's UART pins are
**GPIO28/GPIO29** (confirmed against the board schematic's RP2350 pin table
and the RP2350 datasheet: GPIO28 = UART0 TX, GPIO29 = UART0 RX).

Symptom of the wrong pins: total silence on both CDC ports, whatever you send.

### 5.3 A gateware flash needs a replug

After `make prog`, power-cycle or replug the board before talking to it. The
FPGA reconfigures, but the USB stack and the firmware's view of the link
don't reliably follow without one.

### 5.4 Both USB-CDC ports look identical

macOS/pyserial's `list_ports.comports()` reports the USB *product* string
(`pico-ice`) for both interfaces, not the per-interface description
(`RP2040 logs` vs `iCE40 UART` from `usb_descriptors.c`). No reliable way was
found to disambiguate from the port list alone — try one, and if
`--selftest` fails, try the other. The TPU is on the **`iCE40 UART`** port.

### 5.5 No power-on reset meant `uart_tx` powered up stuck

The most instructive bug in the project, and a real RTL fix rather than a
board workaround.

Every module's registers only reach a known value inside their synchronous
`if (reset)` branch. On this board `reset_n` (push-button, external 10K
pull-up R21) reads **idle-high from the instant the FPGA configures** —
there is no reset IC forcing a pulse — so that branch never fired even once.
Registers took whatever the toolchain's power-on inference produced, and
`uart_tx` came up with `tx_busy` stuck high, transmitting nothing, forever.

Simulation never caught it because every testbench explicitly pulses reset.

Fixed with an internal power-on-reset counter in `tpu_top.sv`, OR'd into
`rst`, so the reset branch always fires at least once regardless of
`reset_n`'s level at configuration time. **Worth guarding against on any
target**, not just this board.

## 6. The bisect ladder

The debugging path that found §5.5, and the right approach whenever the
board goes quiet. Each rung rules out one subsystem instead of guessing at
the whole design:

1. **Bare combinational echo** — `tx_pin = rx_pin`, no clock at all. Tests
   the physical UART wiring in isolation.
2. **Free-running counter on `SB_HFOSC`** — the iCE40's internal oscillator,
   no dependency on the external `clk` pin. Tests whether the fabric runs
   sequential logic.
3. **Same, gated on `reset_n`'s raw level** — tests the reset signal
   specifically.
4. **The real `uart_tx.sv`, with and without a reset dependency** — isolates
   a module's power-up state.

Physical wiring → clock delivery → reset generation → module state.

## 7. Firmware notes

`firmware/main.c` is a minimal fork of `pico-ice-sdk/examples/rp2_usb_uart`.
Its whole job is USB bridging, FPGA clock/config, and LED status.

Two SDK bugs bit this project on real hardware and are fixed here:

- **Silent byte drops.** The SDK's USB→UART bridge drops bytes once the
  RP2350's 32-deep UART TX FIFO fills — which any frame > 32 bytes triggers.
  `main.c` uses a blocking bridge write; `tpu_host.py` additionally paces
  >32-byte writes to wire speed.
- **A TinyUSB race that wedges the whole USB stack.**
  `ice_usb_uart0_to_cdc()` runs in the UART0 RX *interrupt* and calls
  `tud_cdc_n_write_char`/`_flush` — device APIs with no locking under
  `CFG_TUSB_OS=OPT_OS_NONE` — racing the main loop's `tud_task()`. Rare at
  115200; at 1 Mbaud (a byte every ~10 µs) it killed CDC *and* DFU mid-
  regression, requiring a power cycle. `main.c` replaces that ISR with a
  ring-buffer producer and drains it to CDC from the main loop, which is
  then the only TinyUSB caller.

Firmware changes take effect via the SDK's 1200-baud-touch UF2 reboot — no
BOOTSEL press needed. See `firmware/README.md` for the per-file walkthrough.

## 8. Validating a build

```bash
python3 tpu_host.py --port /dev/cu.usbmodemXXXX --selftest       # one golden vector
make hw-test PORT=/dev/cu.usbmodemXXXX \
     ARRAY_ROWS=4 NUM_COLS=4 M_TILE=4 LINK=spi                   # full regression
python3 mnist/infer.py --port /dev/cu.usbmodemXXXX --test-n 20   # end-to-end accuracy
```

The `ARRAY_ROWS`/`NUM_COLS`/`M_TILE`/`LINK` arguments must match **the
bitstream that is actually flashed**, not the Makefile defaults. If you don't
remember what you flashed, `--selftest` at the wrong shape fails on frame
length — that's the quickest way to find out.

See [`verification.md`](verification.md) for what each tier proves.
