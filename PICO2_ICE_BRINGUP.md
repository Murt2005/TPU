# pico2-ice Bring-Up Guide

**Audience:** an agent (or engineer) holding an RTL design that works in simulation only,
with no pico2-ice support yet, who needs to get it running on the board.

**Source:** distilled from this repo's actual bring-up of a TPU systolic array on
pico2-ice — every gotcha below cost real debugging time. Reference implementation files are
cited throughout; read them when you need the full version.

---

## 1. Mental model: what the pico2-ice actually is

Two chips on one board, and **the FPGA is a peripheral of the microcontroller**:

```
   Host PC  ──USB──►  RP2350 (MCU)  ──►  iCE40UP5K (FPGA)
                        │  exports the FPGA's CLOCK (GPOUT0 → pin 35)
                        │  pushes the FPGA's BITSTREAM (USB-DFU → SPI config bus)
                        │  bridges host bytes to the FPGA's UART pins (or SPI)
                        └  drives the onboard LED
```

The four consequences that drive everything else in this document:

| Fact | Consequence |
|---|---|
| The FPGA has **no crystal** — `clk` comes from the RP2350 at a firmware-chosen frequency | Any synthesis-time constant derived from the clock (baud dividers!) must match the firmware's request *numerically*. Mismatch = garbled data, not silence. |
| The FPGA has **no USB and cannot load its own configuration** | The MCU firmware must be flashed and running *before* the gateware can be flashed. |
| The FPGA's **reset button is a plain pull-up**, no reset IC | `reset_n` is idle-high from the instant of configuration. You **must** generate a power-on reset inside the FPGA. This is the #1 bring-up killer. |
| The MCU exposes **two identical-looking USB-CDC ports** | One bridges to the FPGA, one doesn't. You cannot reliably tell them apart on macOS; try both. |

**Hardware budget (iCE40UP5K, package sg48):** 5,280 LCs · 8 `SB_MAC16` DSP blocks ·
30 × 4 Kbit block RAMs · 1 Mbit SPRAM. This repo's design closes timing around 27–32 MHz;
treat ~30 MHz as the realistic fabric ceiling for a nontrivial design.

---

## 2. Prerequisites

```bash
# Toolchain (macOS; on Linux use oss-cad-suite or distro packages)
brew install yosys nextpnr-ice40 icestorm dfu-util icarus-verilog
brew install cmake ninja                       # firmware build
# plus a RISC-V or ARM bare-metal GCC for the RP2350 (see §6)

# Board SDK — vendor as a git submodule, do not copy-paste it
git submodule add https://github.com/tinyvision-ai-inc/pico-ice-sdk firmware/pico-ice-sdk
git submodule update --init --recursive -- firmware/pico-ice-sdk

# Host-side Python
python3 -m venv .venv && source .venv/bin/activate
pip install pyserial numpy
```

> **Trap:** do **not** run `python3 -m venv .` in the repo root. `venv` writes a
> `.gitignore` containing `*` into its target directory — targeting the repo root silently
> hides the entire repo from git. This project hit exactly that. Use `.venv/`.

The two pieces of documentation you will actually need from the vendor:

- `pico-ice-sdk/rtl/pico2_ice.pcf` — **iCE40 package pin numbers** for every named board net.
- `tinyvision-ai-inc/pico2-ice` repo, `Board/Rev1/pico2-ice.pdf` — the schematic, which is
  the authority for **RP2350 GPIO numbers**.

**These are two different namespaces and mixing them produces a silently dead board.**
`pico-ice-sdk/include/boards/pico2_ice.h`'s `ICE_*_PIN` macros are RP2350 GPIO numbers, for
firmware. The `.pcf` numbers are iCE40 package pins, for constraints. Never cross them.

---

## 3. Step 1 — Make the RTL synthesizable

A design that only ever ran under Icarus Verilog will very likely **not** parse in yosys.
Two constructs broke here:

1. **Unpacked-array module ports** — yosys's SystemVerilog frontend cannot parse them.
   Convert to packed 2-D arrays:
   ```systemverilog
   // before (iverilog-only)
   input logic signed [7:0] weights [ROWS][COLS],
   // after (portable)
   input logic signed [ROWS*COLS-1:0][7:0] weights,   // or [ROWS-1:0][COLS-1:0]
   ```
2. **SVA immediate assertions with an `else` clause** — rewrite as `if (...) $fatal(...)`.

The packed conversion then exposes two *latent* bugs that Icarus had been masking, both of
which this project hit:

- **Signedness is lost** on a word-select out of a signed packed 2-D array. Anything
  comparing against zero (ReLU, sign checks) silently breaks. Fix with explicit `$signed()`.
- **Delta-cycle races** in testbenches that read a combinational output in the same timestep
  it is driven. Add a settle delay in the TB.

**Verify:** `make test` (all testbenches still pass under iverilog) **and** a clean
synthesis run, before touching hardware. Also add a Verilator lint pass —
`verilator --lint-only -Wall` over the RTL — with any waivers individually justified in a
`.vlt` file. See `verilator.vlt`.

---

## 4. Step 2 — Write the board top level

Two things the top level must do that a simulation-only design never needed.

### 4.1 Power-on reset generator — do this first, it is not optional

```systemverilog
// Every module's registers only get a known-good value inside their `if (reset)`
// branch. On this board reset_n reads idle-high the instant the FPGA configures
// (plain pull-up, no reset IC), so that branch may NEVER FIRE — leaving registers
// to whatever the toolchain's power-on inference picked. Symptom in this project:
// uart_tx powered up with tx_busy stuck high and never transmitted a single byte,
// while the identical design worked perfectly in simulation (every testbench
// pulses reset at t=0, so the bug is structurally invisible to the test suite).
logic [7:0] por_ctr  = '0;
logic       por_done = 1'b0;
always_ff @(posedge clk) begin
    if (!por_done) begin
        por_ctr <= por_ctr + 1'b1;
        if (por_ctr == 8'hFF) por_done <= 1'b1;
    end
end

logic rst;
assign rst = ~reset_n | ~por_done;   // active-high internal reset
```

Reference: `rtl/tpu_top.sv`. Apply this on any FPGA target, not just this board.

### 4.2 Structure for portability

Keep a **board-neutral core** (`rtl/tpu_core.sv`) holding the datapath and control, and put
only the PHY + POR + pin names in the board top (`rtl/tpu_top.sv`). Define one narrow
byte-stream contract between them:

```
rx_data[7:0] / rx_valid    host → design, one byte, 1-cycle valid pulse
tx_data[7:0] / tx_valid    design → host, one byte
tx_busy                    PHY cannot accept another byte right now
rx_error                   framing error (UART only; tie low elsewhere)
```

This repo used that one contract to swap between a UART PHY, an SPI PHY, and an Avalon-MM
PHY on a completely different FPGA vendor **with zero changes to the core**. It is the
single highest-leverage design decision in the port.

Make array/design geometry and clock/baud into **top-level parameters**, so the FPGA
Makefile can `chparam` them into the bitstream instead of forcing an RTL edit per experiment.

---

## 5. Step 3 — Pin constraints (`.pcf`)

Four pins get you a UART-linked design. Numbers are **iCE40 package pins** from
`pico-ice-sdk/rtl/pico2_ice.pcf`:

```tcl
set_io -nowarn clk      35    # G0 global buffer; driven by RP2350 GPOUT0, NOT a crystal
set_io -nowarn -pullup yes reset_n 10   # ICE_PB push-button, active-low (board has a real 10K pull-up)
set_io -nowarn rx_pin   9     # DEFAULT_UART_RX — bridged to USB-CDC by the firmware
set_io -nowarn tx_pin   11    # DEFAULT_UART_TX

# Only for the optional SPI link (§9): the shared RP2350<->iCE40 config bus.
# Net names read CROSSED because they are named from the flash's perspective:
set_io -nowarn spi_mosi 14    # net ICE_SO  <- RP2350 GPIO7 (spi0 TX)   — FPGA INPUT
set_io -nowarn spi_sck  15    #                RP2350 GPIO6
set_io -nowarn spi_csn  16    #                RP2350 GPIO5 (shared with flash CS!)
set_io -nowarn spi_miso 17    # net ICE_SI  -> RP2350 GPIO4 (spi0 RX)   — FPGA OUTPUT
```

Reference: `fpga/ice40/tpu_top.pcf`, which documents the reasoning for each pin.

---

## 6. Step 4 — The FPGA build flow

`yosys → nextpnr-ice40 → icepack → dfu-util`. Skeleton (full version:
`fpga/ice40/Makefile`):

```make
CLK_FREQ  ?= 12000000        # MUST equal the firmware's ice_fpga_init() request
BAUD_RATE ?= 1000000         # 1 Mbaud = exact /12 of 12 MHz → zero baud error

$(TOP).json: $(RTL)
	yosys -q -p "read_verilog -sv $(RTL); \
		chparam -set CLK_FREQ $(CLK_FREQ) $(TOP); \
		chparam -set BAUD_RATE $(BAUD_RATE) $(TOP); \
		synth_ice40 -top $(TOP) -dsp -abc9 -dff -json $@"

$(TOP).asc: $(TOP).json $(PCF)
	nextpnr-ice40 -q --up5k --package sg48 --pcf $(PCF) --json $< --asc $@

$(TOP).bin: $(TOP).asc
	icepack $< $@

prog: $(TOP).bin
	dfu-util -d 1209:b1c0 -a 0 -D $< -R
```

**Stage the flow** (`make json` / `asc` / `bin`) so each intermediate is inspectable, and add
three diagnostic targets — you will use them constantly:

- `make stat` — yosys post-synthesis cell/LUT/FF breakdown. Run it on modules *standalone*
  to attribute area when you overflow.
- `make util` — nextpnr device utilisation (LC / DSP / BRAM / IO vs. the UP5K budget).
- `make time` — `icetime` post-PnR fMax against your clock constraint.
  *(Some Homebrew icestorm installs can't resolve `-d up5k`; fall back to
  `-C $(brew --prefix icestorm)/share/icestorm/chipdb/chipdb-5k.txt`.)*

**Synthesis flags worth knowing on this chip:**

| Flag | Effect measured in this project |
|---|---|
| `-dsp` | Maps multiplies onto the 8 hard `SB_MAC16` blocks: ~251 → ~36 LUTs per multiplier; whole design 2,592 → 2,138 LCs. **Caveat:** it maps *every* inferred multiply with no per-instance opt-out — so it caps you at 8 multipliers, it can't do "8 hard + N soft". |
| `-abc9 -dff` | Register-aware ABC pass; swept ~1,050 duplicated staging FFs. 5,484 → 5,072 LCs — the difference between not fitting and fitting. |
| `(* ram_style = "block" *)` | Forces a memory into block RAM instead of LUTs. Moved this design 5,072 → 4,935 LCs by relocating one buffer into 2 of 29 idle BRAMs. |

**Placement note:** ≥96% LC utilisation *packs* but reliably **fails to place** (multiple
nextpnr seeds and `--placer sa` all failed legalization here). Budget for ≤93%.

---

## 7. Step 5 — The RP2350 firmware

Fork `pico-ice-sdk/examples/rp2_usb_uart`. It has exactly three jobs: export the clock, let
the FPGA configure, and bridge bytes. Reference: `firmware/main.c`, `firmware/README.md`.

```c
#define UART_TX_PIN 28    // NOT 0/1 — see gotcha G2
#define UART_RX_PIN 29

int main(void) {
    uart_init(uart0, 115200);
    gpio_set_function(UART_TX_PIN, GPIO_FUNC_UART);
    gpio_set_function(UART_RX_PIN, GPIO_FUNC_UART);

    ice_usb_init();                             // 2× CDC-ACM + 1× DFU composite device

    ice_fpga_init(FPGA_DATA, AS_MHZ(12));       // MUST equal the Makefile's CLK_FREQ.
                                                // SDK default is 48 MHz — too fast for
                                                // most designs on this part.
    ice_fpga_start(FPGA_DATA);

    // Real CDONE check — see gotcha G3. Declared nowhere public; declare it yourself:
    //   extern int ice_fpga_configured(const ice_fpga fpga);
    ice_led_init();
    ice_fpga_configured(FPGA_DATA) == 0 ? ice_led_green(true) : ice_led_red(true);

    while (true) { tud_task(); /* + your bridge servicing */ }
}
```

### 7.1 Two SDK bridge bugs you must fix (both bit this project on real hardware)

**Host → FPGA: the SDK silently drops bytes.** `ice_usb_cdc_to_uart0()` does
`if (uart_is_writable(uart0)) uart_putc(...)` — so once the RP2350's **32-deep** UART TX FIFO
fills, the tail of any longer burst is lost. Fine for ≤11-byte frames, fatal the moment you
introduce batched commands. Replace the CDC RX callback with a **blocking** write
(`uart_putc_raw`), which lets TinyUSB's CDC flow control NAK the host instead:

```c
extern void (*tud_cdc_rx_cb_table[])(uint8_t);
static void cdc_to_uart0_blocking(uint8_t b) { uart_putc_raw(uart0, b); }
tud_cdc_rx_cb_table[ICE_USB_UART0_CDC] = &cdc_to_uart0_blocking;
```
Belt-and-braces: also pace writes >32 bytes to wire speed on the host side.

**FPGA → host: an ISR/TinyUSB race that wedges the whole USB stack.**
`ice_usb_uart0_to_cdc()` runs in the UART0 RX **interrupt** and calls TinyUSB device APIs,
which have no locking under `CFG_TUSB_OS=OPT_OS_NONE` — racing the main loop's `tud_task()`.
At 115200 the window is rarely hit; at 1 Mbaud (a byte every ~10 µs) it wedges **CDC and DFU
alike**, requiring a power cycle. Demote the ISR to a ring-buffer producer and drain from the
main loop, so there is exactly one TinyUSB caller:

```c
irq_set_enabled(UART0_IRQ, false);
irq_remove_handler(UART0_IRQ, irq_get_exclusive_handler(UART0_IRQ));
irq_set_exclusive_handler(UART0_IRQ, uart0_rx_to_ring);   // ISR: ring buffer only
irq_set_enabled(UART0_IRQ, true);
// main loop: while (ring not empty && tud_cdc_n_write_available(...)) { write; } flush;
```
A 4 KB SPSC ring outlasts any protocol response burst.

### 7.2 Building it

```bash
cd firmware && mkdir -p build && cd build
cmake -DPICO_BOARD=pico2_ice -DPICO_PLATFORM=rp2350-riscv \
      -DPICO_GCC_TRIPLE=riscv64-unknown-elf -G Ninja ..
ninja                       # -> pico2_ice_bridge.uf2
```
ARM instead: `-DPICO_PLATFORM=rp2350-arm-s` (drop `-DPICO_GCC_TRIPLE`), with
`arm-none-eabi-gcc` on `PATH`. First configure builds `picotool` from source.

**You only rebuild firmware when the RP2350 side changes** (clock, pins, bridge behavior).
Pure RTL changes need only a gateware rebuild + reflash.

---

## 8. Step 6 — Flash and validate

**Order matters: firmware first, then gateware.** `dfu-util` needs the firmware's DFU USB
interface already enumerated before it can push a bitstream.

1. **Firmware** — hold **BOOTSEL** while plugging in USB. The board mounts as a drive; copy
   `pico2_ice_bridge.uf2` onto it. It reboots automatically.
   *After the first flash you never need BOOTSEL again:* open the TPU CDC port at **1200
   baud** and the board reboots into the UF2 bootloader on its own.
2. **Check the LED** — green = FPGA configured (real `CDONE` check), red = it isn't.
3. **Gateware** — `cd fpga/ice40 && make prog`.
   **Ignore `dfu-util`'s "Device's firmware is corrupt" message — it is a known false alarm
   printed on every flash** (gotcha G3).
4. **Replug** so the boot-time `CDONE` check re-runs against the new bitstream; re-check LED.
5. **Find the port:**
   ```bash
   python3 -c "import serial.tools.list_ports as p; [print(x) for x in p.comports()]"
   ```
   Both CDC ports show the same product string on macOS. Try the **higher-numbered**
   `/dev/cu.usbmodemN` first; the other is the log port.
6. **Validate, in this order — never skip a rung:**
   ```bash
   dfu-util -l                                     # firmware enumerated? (2 DFU alts listed)
   python3 tpu_host.py --port /dev/cu.usbmodemN --selftest    # one known-golden vector
   make hw-test PORT=/dev/cu.usbmodemN             # full regression against silicon
   ```

---

## 9. Optional: the SPI host link (2.7× faster, and it unlocks a faster clock)

Worth doing once the UART path works, and **only** then — keep the UART build as a bisect
fallback behind a `USE_SPI` parameter. Reference: `rtl/spi_slave.sv`, `firmware/tpu_tile.c`.

**Why it wins:** the UART's baud divider is baked in at synthesis against `CLK_FREQ`, which
pins the design's clock. An SPI slave has no divider, so the core clock can rise to whatever
fMax allows — this project went 12 → 24 MHz and gained 2.7× end-to-end.

**Design contract:** write a mode-0 (CPOL=0, CPHA=0) slave presenting the *identical*
byte-stream interface as the UART PHY, so the core is untouched. Then:

- **SPI is master-driven, so request/response becomes write-then-poll.** The master clocks
  the command frame out, then clocks dummy `0xFF` filler and watches MISO. Return a reserved
  `IDLE_BYTE` (`0x00`) while no response is queued; the first non-idle byte is STATUS.
  **Make `0xFF` a NOP in your protocol's idle state** — otherwise your own poll filler parses
  as commands.
- **The master must deassert CS between the write burst and the read poll**, and between
  frames; CS resets bit alignment. MISO during a write burst is garbage — discard it.
- **Clock caps, both tighter than the PHY's raw limit:**
  - *Write* ≤ `CLK/6` — not a PHY limit but a **protocol** one: if your sequencer has no RX
    backpressure and drops bytes during an inter-frame processing pass (~25–35 clk here),
    the byte period must exceed it. 4 MHz at a 24 MHz core.
  - *Read* ≤ `CLK/8` — SCK edge detection through a 2FF synchronizer needs ≥3 clk per half
    period. 3 MHz at 24 MHz. Responses are tiny, so the slow read leg costs microseconds.
- **The onboard SPI flash shares this bus** (same CS net). The firmware must park it in
  **deep power-down (`0xB9`)** at startup — and note the FPGA also *sees* that frame and will
  answer with an unknown-command error, which the firmware must drain.
- `rx_error` has no SPI equivalent (no framing) — tie it low in SPI builds.

RP2350 side: `spi0` on GPIO 4 (RX/MISO) / 5 (CS) / 6 (SCK) / 7 (TX/MOSI), with CS driven as
a plain GPIO so you control burst boundaries.

---

## 10. Gotcha table — read before debugging blind

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| **G1** | Design works in sim, transmits **nothing** on hardware | No power-on reset: `reset_n` is idle-high at configuration, so every `if (reset)` branch never fires; registers power up in toolchain-chosen states | Internal POR counter OR'd into reset (§4.1) |
| **G2** | **Total silence on both CDC ports**, whatever you send | Upstream example hardcodes RP2350 GPIO0/GPIO1 — those are the onboard **LEDs** on pico2-ice (RP2040-era pinout). The FPGA UART is GPIO28/29 | Use 28/29; verify against the schematic, not the example |
| **G3** | `dfu-util`: *"Device's firmware is corrupt"* on every flash | SDK's DFU manifest callback reports `ok = ice_fpga_start(...)`, but that function unconditionally `return 0` (falsy) and never polls CDONE | Ignore the message; call `ice_fpga_configured()` yourself and show it on the LED |
| **G4** | Board alive, responses **garbled** (not absent) | `CLK_FREQ` in the Makefile ≠ `ice_fpga_init()` in firmware — the baud divider is a synthesis-time constant | Change both together, reflash both images |
| **G5** | Long frames lose their **tail**; short ones fine | SDK's CDC→UART bridge drops bytes when the 32-deep TX FIFO fills | Blocking bridge write + host-side pacing (§7.1) |
| **G6** | Entire USB stack (CDC **and** DFU) hangs; power cycle required. Appears only at high baud | UART RX ISR calls unlocked TinyUSB APIs, racing `tud_task()` | Ring buffer in ISR, drain from main loop (§7.1) |
| **G7** | Both serial ports look identical | macOS/pyserial shows the USB product string, not the per-interface description | Trial and error; higher-numbered port first |
| **G8** | Design **packs** at 96% but nextpnr **fails to place** | UP5K placement legalization gives out well below 100% | Budget ≤93% LC; use `-abc9 -dff` and BRAM inference to get there |
| **G9** | yosys can't parse RTL that iverilog accepts | Unpacked-array ports / SVA `else` clauses | Convert to packed arrays; `if/$fatal` (§3) |
| **G10** | Sign comparisons break *after* the packed-array conversion | Word-select out of a signed packed 2-D array loses signedness | Explicit `$signed()` casts |
| **G11** | `make time` — *"Can't find chipdb file"* | Some Homebrew icestorm installs can't resolve `-d up5k` | Pass `-C .../chipdb-5k.txt` directly |
| **G12** | Whole repo vanishes from `git status` | `python3 -m venv .` in the repo root overwrote `.gitignore` with `*` | Use `.venv/`; check `git diff .gitignore` after |

---

## 11. When it doesn't work: the bisect ladder

This is the procedure that actually found G1. Build **minimal bitstreams** that eliminate one
subsystem at a time, rather than debugging the full design:

1. **Bare combinational echo** — `assign tx_pin = rx_pin;`, no clock at all.
   Tests physical wiring + firmware bridge in isolation. If this fails, the problem is pins,
   firmware, or the port you picked — not your design.
2. **Free-running counter on `SB_HFOSC`** (the iCE40's internal oscillator) driving the LED
   or a pin. Tests whether the fabric runs sequential logic *without* depending on the
   external clock. If step 1 passes and this fails, the FPGA isn't configured.
3. **Same counter, but on the external `clk` pin.** Isolates clock delivery from the RP2350.
   If this fails, `ice_fpga_init()`/`ice_fpga_start()` or the clock pin constraint is wrong.
4. **Same counter, gated on `reset_n`'s raw level.** Isolates the reset signal.
5. **Your PHY module alone**, driven with and without a reset dependency. This is the step
   that isolates G1-class bugs.

Then instrument at the protocol level: a host driver that resyncs and probes the device on
connect turns two nasty silent failure modes (a desynced state machine eating the *next*
session's bytes; a host/bitstream parameter mismatch) into one immediate, explicit error.
See `tpu_host.py`'s `_resync_and_probe_shape()`.

---

## 12. Protocol design advice (learned the expensive way)

If you're defining a host↔FPGA wire protocol as part of this port:

- **Simple framing first:** `[CMD][LEN][payload]` / `[STATUS][LEN][payload]`, host-initiated,
  one outstanding request. Easy to resync, easy to test.
- **Keep opcodes in one shared package** (`rtl/tpu_pkg.sv`) imported by the RTL and mirrored
  in the host driver. Note: yosys only accepts a **file-scope** `import` — before the module,
  not inside it. Icarus and Verilator accept that form too.
- **Instrument wire bytes and round-trips per command type from day one.** This project's
  entire 125× optimization campaign started with a measurement showing the *actual compute*
  was 0.1% of wall-clock time — 7,429 USB round trips per inference were the real cost. You
  cannot optimize what you haven't attributed.
- **Batching beats bit-twiddling.** The three largest wins here were, in order: batching many
  operations into one frame, raising the link rate, and moving the inner loop onto the MCU
  (one USB round trip per layer instead of per tile). Each transaction costs ~0.5 ms of pure
  USB/host overhead regardless of payload size.
- **Every optimization gets an A/B bit-identity test against the unoptimized path**, in the
  hardware regression suite — not just a speed measurement.
- **Don't buffer whole frames in FPGA registers.** A 255-byte register buffer is prohibitive
  on a UP5K. Deserialize straight into your working registers and exploit the fact that the
  wire byte cadence dwarfs your compute pass.

---

## 13. Checklist

**Port**
- [ ] RTL parses in yosys (packed ports, no SVA `else`); testbenches still pass in iverilog
- [ ] `$signed()` casts audited after the packed-array conversion
- [ ] Verilator lint clean, waivers justified
- [ ] Board-neutral core extracted; PHY behind a narrow byte-stream interface
- [ ] **Power-on reset generator in the top level**
- [ ] `.pcf` written from `pico2_ice.pcf` package pins (not RP2350 GPIO numbers)
- [ ] Clock/baud/geometry are top-level parameters, `chparam`'d from the Makefile

**Build**
- [ ] `yosys → nextpnr → icepack → dfu-util` staged, with `stat`/`util`/`time` targets
- [ ] Utilisation ≤93% LC, timing closes with margin at your target clock
- [ ] `CLK_FREQ` (Makefile) == `ice_fpga_init()` (firmware) — checked, not assumed

**Firmware**
- [ ] Forked from `rp2_usb_uart`; UART on **GPIO28/29**
- [ ] `ice_fpga_init()` at a frequency your design actually closes at (not the 48 MHz default)
- [ ] Real `CDONE` check via `ice_fpga_configured()`, surfaced on the LED
- [ ] Blocking CDC→UART bridge write (no silent drops)
- [ ] UART RX ISR is ring-buffer-only; single TinyUSB caller in the main loop

**Bring-up**
- [ ] Firmware flashed **before** gateware; replug after gateware
- [ ] LED green; `dfu-util -l` lists both DFU alt interfaces
- [ ] `--selftest` passes against a known golden vector from simulation
- [ ] Full hardware regression passes, including randomized stress
