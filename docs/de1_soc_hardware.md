# DE1-SoC Hardware Reference

Reference document for the Terasic DE1-SoC development board used as the deployment target for this TPU project.

---

## 1. Board Identity

| Field | Value |
|---|---|
| Board | Terasic DE1-SoC Development and Education Kit |
| FPGA/SoC chip | Intel (Altera) Cyclone V SE SoC — **5CSEMA5F31C6N** |
| Package | 672-pin FBGA (F31) |
| Speed grade | Commercial (C6) |
| Main clock inputs | 4× 50 MHz oscillators; `CLOCK_50` (PIN_AF14) is the standard Quartus entry point |

**Part number decoding:** `5C` = Cyclone V, `SE` = SoC with HPS (SE variant), `MA5` = A5 density, `F31` = 672-pin BGA, `C6` = commercial grade.

---

## 2. FPGA Fabric Resources

| Resource | Count | Notes |
|---|---|---|
| Adaptive Logic Modules (ALMs) | 32,070 | Each ALM = 8-input fracturable LUT + 2 flip-flops + carry chain |
| Equivalent Logic Elements | ~85,000 | Marketing figure ≈ ALMs × 2.7 |
| M10K block RAM blocks | **553** | 10,240 bits each → **5,662,720 bits ≈ 707 KB total** |
| DSP 18×18 MAC blocks | **87** | Each does one signed 18×18 multiply-accumulate per cycle; also configurable as 2× 9×9 |
| Fractional PLLs | 6 | Can synthesize derived clocks from the 50 MHz input |
| GPIO expansion headers | 2× 40-pin | GPIO0 (JP1), GPIO1 (JP2) — 3.3V I/O with diode protection |

### M10K Block RAM

- **Capacity:** 10,240 bits per block (configurable as 8K×1, 4K×2, 2K×4/5, 1K×8/10, 512×16/20, 256×32/40 — or wider with multiple blocks cascaded)
- **Port modes:** True dual-port, simple dual-port, single-port RAM or ROM
- **Read latency:** **2 clock cycles** in fully-registered mode (registered address input, registered data output). RTL reading from M10K must account for this pipeline delay.
- **Inference:** Quartus automatically maps `logic [W-1:0] mem [DEPTH]` arrays to M10K blocks when size exceeds a threshold (~256 bits). Cascades multiple blocks automatically for larger arrays.

### DSP Blocks

- Signed 18×18 multiply → 36-bit result, with optional accumulator
- The PE module uses int8 (8-bit) weights × int8 activations → 16-bit partial sum, well within one DSP block per PE
- 2×2 array = 4 DSPs; 8×8 array = 64 DSPs — both fit within the 87-block budget

---

## 3. Hard Processor System (HPS)

The HPS is a hard ARM subsystem inside the Cyclone V SoC die, sharing silicon with the FPGA fabric.

| Feature | Detail |
|---|---|
| Processor | Dual-core ARM Cortex-A9 MPCore |
| Clock | Up to 925 MHz (925 MHz max spec; typical operating ~800 MHz under Linux) |
| L1 cache | 32 KB I-cache + 32 KB D-cache per core |
| L2 cache | 512 KB shared (PL310 controller) |
| HPS DDR3 SDRAM | **1 GB** soldered, 32-bit bus at 400 MHz (800 MT/s) |
| Boot media | microSD card (FAT32 partition for U-Boot + ext4 for Linux rootfs) |
| USB OTG | 1× USB 2.0 |
| Ethernet | 1× Gigabit Ethernet (connected to HPS only) |
| UART | 1× on-board USB-to-serial (115200 8N1) |
| SPI / I2C | Available on HPS GPIO headers |
| Timers | Several hardware timers in HPS peripheral region |

---

## 4. FPGA-Side Peripherals

These are connected directly to FPGA I/O pins (not the HPS).

| Peripheral | Quantity / Detail |
|---|---|
| **FPGA SDRAM** | 64 MB, 16-bit data bus, 167 MHz — separate from the HPS 1 GB DDR3 |
| **Red LEDs** | 10 (`LEDR[9:0]`), active-high |
| **7-Segment displays** | 6 units (`HEX0`–`HEX5`), common-anode, **active-low** segments |
| **Push buttons** | 4 (`KEY[3:0]`), active-low, hardware-debounced |
| **Slide switches** | 10 (`SW[9:0]`), active-high when up |
| **VGA output** | 8-bit resistor-DAC (3 channels R/G/B), DB-15 connector, up to 1280×1024 |
| **PS/2 connector** | 1 (keyboard or mouse) |
| **IR receiver** | 1 |
| **Audio CODEC** | Wolfson WM8731, 24-bit, Line In / Line Out / Mic In |
| **USB Blaster II** | On-board JTAG programmer — programs FPGA directly from Quartus |

---

## 5. HPS ↔ FPGA Bridges

All bridges are held in reset after power-up. Software must release them before use.

**Release sequence (ARM C code):**
```c
// 1. Map the HPS system manager
volatile uint32_t *sysm = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE,
                               MAP_SHARED, fd_devmem, 0xFFD05000);
// 2. Clear bridge reset bits (bits 0=H2F, 1=LWH2F, 2=F2H)
sysm[0x07] &= ~0x7;   // brgmodrst register at offset 0x1C / 4

// 3. Remap (set H2F and LWH2F visible to L3 masters)
volatile uint32_t *l3regs = mmap(..., 0xFF800000);
l3regs[0] |= (1<<3) | (1<<4);  // remap register
```

| Bridge | Direction | Data width | HPS address range | Use in this project |
|---|---|---|---|---|
| **Lightweight HPS-to-FPGA (LWH2F)** | HPS → FPGA | 32-bit AXI4-Lite | `0xFF20_0000 – 0xFF3F_FFFF` (2 MB) | **V1 primary interface** — CSRs, control/status, packed data |
| HPS-to-FPGA (H2F) | HPS → FPGA | 32/64/128-bit AXI4 | 960 MB window | Bulk activation/weight DMA (future) |
| FPGA-to-HPS (F2H) | FPGA → HPS | 32/64/128-bit AXI4 | 960 MB window | FPGA-initiated HPS memory access (future) |
| FPGA-to-SDRAM (F2S) | FPGA → HPS DDR3 | 32/64/128/256-bit | Full 4 GB SDRAM space | FPGA DMA to DDR3 bypassing ARM (stretch) |
| ACP (Accelerator Coherency Port) | FPGA → L2 cache | 64-bit AXI4 | 1 GB L2-coherent window | Cache-coherent DMA (stretch) |

### V1 Strategy: LWH2F Only

The ARM program opens `/dev/mem`, mmap's `0xFF20_0000`, and accesses the FPGA CSR block as a plain C array of `volatile uint32_t`. No kernel driver, no DMA — just CPU-driven register reads/writes. Sufficient for MNIST inference where the input (784 bytes) and output (10 bytes) are tiny.

```c
volatile uint32_t *fpga = mmap(NULL, 0x200000, PROT_READ|PROT_WRITE,
                               MAP_SHARED, fd_devmem, 0xFF200000);
fpga[CTRL]   = 0x1;          // START
while (!(fpga[STATUS] & 0x2)); // poll DONE
int result = fpga[DATA_OUT];
```

---

## 6. FPGA Configuration Methods

| Method | When to use |
|---|---|
| **USB Blaster II (JTAG)** | During development — Quartus Programmer writes `.sof` in seconds; volatile, cleared on power cycle |
| **SD card `.rbf`** | Deployment — U-Boot or Linux loads `.rbf` at boot; MSEL pins must be `5'b01010` |
| Active Serial (EPCS flash) | Production/standalone — programs on-board flash; persists across power cycles without SD card |

**Converting `.sof` → `.rbf` (required for SD card boot):**
Quartus menu → File → Convert Programming Files → Output file type: Raw Binary File (`.rbf`) → no compression → Generate.

**MSEL configuration for HPS-controlled programming (SD card flow):**
The MSEL[4:0] DIP switches on the board must be set to `5'b01010` (MSEL4=0, MSEL3=1, MSEL2=0, MSEL1=1, MSEL0=0).

---

## 7. Pin Assignments

### Clocks

| Signal | FPGA Pin | Notes |
|---|---|---|
| `CLOCK_50` | AF14 | 50 MHz — primary system clock input |
| `CLOCK2_50` | AA16 | Second 50 MHz oscillator |
| `CLOCK3_50` | Y26 | Third 50 MHz oscillator |
| `CLOCK4_50` | K14 | Fourth 50 MHz oscillator (often used for SDRAM PLL) |

### User I/O

| Signal | FPGA Pin(s) | Direction | Notes |
|---|---|---|---|
| `KEY[0]` | AA14 | Input | Active-low push button; reset |
| `KEY[1]` | AA15 | Input | Active-low; trigger inference |
| `KEY[2]` | W15 | Input | Active-low |
| `KEY[3]` | Y16 | Input | Active-low |
| `SW[0]` | AB12 | Input | Active-high when up |
| `SW[9:0]` | AB12 – AD7 | Input | See user manual Table 3-2 for all 10 |
| `LEDR[0]` | V16 | Output | Active-high red LED |
| `LEDR[9:0]` | V16 – W15 | Output | See user manual Table 3-3 |
| `HEX0[6:0]` | AE26, AE27, AE28, AG27, AF28, AG28, AH28 | Output | Active-low segments; bit 0 = segment a |
| `HEX1[6:0]` | AJ29, AH29, AH30, AG30, AF29, AF30, AD27 | Output | Active-low |
| `HEX2[6:0]` | AB23, AE29, AD29, AC28, AD30, AC29, AC30 | Output | Active-low |
| `HEX3[6:0]` | AD26, AA24, Y23, AA25, AB24, AB23, AA23 | Output | Active-low |
| `HEX4[6:0]` | AA25, AA26, Y25, W26, Y26, W27, W28 | Output | Active-low |
| `HEX5[6:0]` | V25, AA28, Y27, AB27, AB26, AA27, AA26 | Output | Active-low |

**Full pin table:** See Terasic DE1-SoC User Manual Chapter 3, or use the community TCL script at:
`Altera-FPGA-top-level-files/DE1-SoC/pin_assignment_DE1_SoC.tcl` (sahandKashani on GitHub).

---

## 8. 7-Segment Display Encoding

The six displays are common-anode (active-low): driving a segment pin LOW turns it ON.

```
Segment layout:
   aaa
  f   b
  f   b
   ggg
  e   c
  e   c
   ddd  (dp = decimal point, not used here)

Bit mapping: HEX[6:0] = { g, f, e, d, c, b, a }
             HEX[0] = segment a (top horizontal bar)
             HEX[6] = segment g (middle horizontal bar)
```

| Digit | HEX[6:0] (binary) | HEX[6:0] (hex) |
|---|---|---|
| 0 | 7'b100_0000 | 0x40 |
| 1 | 7'b111_1001 | 0x79 |
| 2 | 7'b010_0100 | 0x24 |
| 3 | 7'b011_0000 | 0x30 |
| 4 | 7'b001_1001 | 0x19 |
| 5 | 7'b001_0010 | 0x12 |
| 6 | 7'b000_0010 | 0x02 |
| 7 | 7'b111_1000 | 0x78 |
| 8 | 7'b000_0000 | 0x00 |
| 9 | 7'b001_0000 | 0x10 |
| Off | 7'b111_1111 | 0x7F |

A 4-bit → 7-segment decoder belongs in `rtl/seg7_decoder.sv` as a simple `case` statement, instantiated in `tpu_top.sv` to display the argmax digit after inference.

---

## 9. Development Toolchain

| Tool | Version / Source | Purpose |
|---|---|---|
| **Quartus Prime Lite** | 19.1 or later (free, intel.com/programmable) | Synthesis, place & route, timing analysis, programming |
| **Platform Designer (Qsys)** | Bundled with Quartus | Generate HPS component + bridge interconnect HDL |
| **ModelSim-Intel / Questa** | Bundled with Quartus | Simulation (optional — Icarus Verilog already used in this project) |
| **Icarus Verilog** | Already installed | Fast unit/integration simulation (`iverilog` + `vvp`) |
| **GTKWave** | Already installed | Waveform viewer for `.vcd` dumps |
| **ARM cross-compiler** | `arm-linux-gnueabihf-gcc` (`brew install arm-linux-gnueabihf-binutils` or via apt) | Compile HPS C programs on the host |
| **SoC EDS** | Intel download (optional) | BSP editor, `hps_0.h` peripheral header generation, DS-5 IDE |
| **`quartus_pgm`** | Part of Quartus installation | CLI JTAG programming (scriptable) |
| **Python + PyTorch** | Already expected for weight export | Train MLP, quantize to int8, export `.mem` files |

---

## 10. Recommended Development Flow

```
Step 1 — Simulation (already working)
  make test                        # all 13 Icarus testbenches pass
  # Continue: implement UB, weight_loader, host_interface, tpu_top
  # each gets a testbench before the next module is started

Step 2 — Quartus project setup
  - New project wizard → target device: 5CSEMA5F31C6
  - Import Terasic pin assignments (pin_assignment_DE1_SoC.tcl)
  - Add rtl/*.sv as project source files
  - Set tpu_top as top-level entity

Step 3 — Platform Designer (only needed for LWH2F bridge)
  - Add HPS component → enable LWH2F bridge
  - Add Avalon-MM or AXI4-Lite slave interface mapped to host_interface.sv
  - Generate HDL → include generated .qip in Quartus project

Step 4 — Compile (Analysis + Synthesis + Fitter + Timing Analyzer)
  - Check resource utilization: ALMs, M10K blocks, DSP blocks
  - Check Timing Analyzer: meet setup/hold at 50 MHz (or PLL target)
  - Fix any synthesis warnings (latches, undriven signals)

Step 5 — Program via USB Blaster II (JTAG, development)
  quartus_pgm -m jtag -o "p;output_files/tpu_top.sof@1"
  # Or use Quartus Programmer GUI

Step 6 — HPS software test
  # Cross-compile on host:
  arm-linux-gnueabihf-gcc -O1 -o tpu_test tpu_test.c
  # Transfer to DE1-SoC (via SSH or SD card)
  # On the board:
  sudo ./tpu_test
  # Program: open /dev/mem, mmap 0xFF200000, release bridges,
  #          write weights + input image, assert START, poll DONE, read digit

Step 7 — Deploy via SD card (optional, standalone)
  - Convert output_files/tpu_top.sof → output_files/tpu_top.rbf (no compression)
  - Place tpu_top.rbf on SD card FAT32 partition
  - Edit U-Boot script to load and program FPGA at boot
  - Set MSEL[4:0] = 5'b01010 on the board DIP switches
```

---

## 11. Resource Budget for This Project

| Resource | Available | MNIST 2×2 estimate | MNIST 8×8 estimate | Headroom (8×8) |
|---|---|---|---|---|
| ALMs | 32,070 | ~500 | ~2,000 | ~94% free |
| M10K blocks | 553 | ~2 (UB + weight ROM) | ~12 (larger UB + ROM) | ~98% free |
| DSP blocks | 87 | 4 (one per PE) | 64 (one per PE) | 26% free (still fits) |

**MNIST weight memory:** 784×128 + 128×10 = 100,352 + 1,280 = **101,632 int8 bytes ≈ 99 KB** — fits in ~10 M10K blocks, leaving 543 blocks for the Unified Buffer and other structures.

---

## 12. Useful References

- [Terasic DE1-SoC product page](http://de1-soc.terasic.com/)
- [DE1-SoC User Manual v1.2.2 (Cornell mirror)](https://people.ece.cornell.edu/land/courses/ece5760/DE1_SOC/DE1-SoC_User_manualv.1.2.2_revE.pdf)
- [SoC-FPGA Design Guide (EPFL)](https://people.ece.cornell.edu/land/courses/ece5760/DE1_SOC/SoC-FPGA%20Design%20Guide_EPFL.pdf)
- [HPS Introduction — Cyclone V (Cornell)](https://people.ece.cornell.edu/land/courses/ece5760/DE1_SOC/HPS_INTRO_54001.pdf)
- [Cornell ECE5760 DE1-SoC resource index](https://people.ece.cornell.edu/land/courses/ece5760/DE1_SOC/index.html)
- [Cyclone V 5CSEMA5 resource page (Altera)](https://www.altera.com/products/fpga/cyclone/v/se/5csea5-f31/5CSEMA5F31C6N)
- [CycloneVSoC-examples (GitHub)](https://github.com/robertofem/CycloneVSoC-examples)
- [sahandKashani pin assignment TCL (GitHub)](https://github.com/sahandKashani/Altera-FPGA-top-level-files/blob/master/DE1-SoC/pin_assignment_DE1_SoC.tcl)
