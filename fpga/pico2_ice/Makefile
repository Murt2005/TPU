## ============================================================================
##  tpu_top build for the pico2-ice board (iCE40UP5K, package sg48)
##
##  Toolchain: yosys (synth) -> nextpnr-ice40 (place & route) -> icepack (bitstream)
##  Install via `brew install yosys nextpnr-ice40 icestorm dfu-util` or oss-cad-suite.
##
##  Usage:
##    make            Build tpu_top.bin
##    make time        Print a static timing report (post-PnR fMax)
##    make prog        Flash tpu_top.bin over USB DFU (board must be in DFU mode)
##    make clean       Remove build artifacts
##
##  CLK_FREQ:
##    tpu_top's `clk` pin is not a fixed crystal -- it's exported by the
##    RP2350 over GPOUT0 (see pico-ice-sdk/include/ice_fpga.h), at whatever
##    frequency the RP2350 firmware requests via ice_fpga_init(). CLK_FREQ
##    here must match that firmware's request, since it sets the UART
##    baud-rate divider computed at synthesis time. Default 12 MHz leaves
##    ~2.6x margin under this design's measured ~32 MHz fMax on an UP5K
##    (see tpu_top.pcf for more on the clock path).
## ============================================================================

YOSYS    := yosys
NEXTPNR  := nextpnr-ice40
ICEPACK  := icepack
ICETIME  := icetime
DFU_UTIL := dfu-util

RTL_DIR := ../../rtl
TOP     := tpu_top
PCF     := tpu_top.pcf

CLK_FREQ ?= 12000000

# DFU alt-setting the FPGA bitstream (flash) lives on for this board's
# default firmware -- matches pico-ice-sdk's own example Makefiles.
DFU_ALT_FLASH := 0

RTL := $(RTL_DIR)/uart_rx.sv \
       $(RTL_DIR)/uart_tx.sv \
       $(RTL_DIR)/tpu_sequencer.sv \
       $(RTL_DIR)/unified_buffer.sv \
       $(RTL_DIR)/weight_fifo.sv \
       $(RTL_DIR)/fifo.sv \
       $(RTL_DIR)/systolic_data_setup.sv \
       $(RTL_DIR)/mmu.sv \
       $(RTL_DIR)/pe.sv \
       $(RTL_DIR)/accumulator.sv \
       $(RTL_DIR)/bias.sv \
       $(RTL_DIR)/activation.sv \
       $(RTL_DIR)/tpu_top.sv

.PHONY: all time prog clean

all: $(TOP).bin

$(TOP).json: $(RTL)
	$(YOSYS) -q -p "\
		read_verilog -sv $(RTL); \
		chparam -set CLK_FREQ $(CLK_FREQ) $(TOP); \
		synth_ice40 -top $(TOP) -json $@"

$(TOP).asc: $(TOP).json $(PCF)
	$(NEXTPNR) -q --up5k --package sg48 --pcf $(PCF) --json $(TOP).json --asc $@

$(TOP).bin: $(TOP).asc
	$(ICEPACK) $< $@

# Some icestorm installs (e.g. Homebrew, as of icestorm 1.1) fail to resolve
# the up5k chipdb via `-d up5k` ("Can't find chipdb file for device 5k").
# If `make time` hits that, point ICETIME_CHIPDB at the file directly, e.g.:
#   make time ICETIME_CHIPDB=$$(brew --prefix icestorm)/share/icestorm/chipdb/chipdb-5k.txt
ICETIME_CHIPDB ?=
ICETIME_DEVICE := $(if $(ICETIME_CHIPDB),-C $(ICETIME_CHIPDB),-d up5k)

time: $(TOP).asc
	$(ICETIME) $(ICETIME_DEVICE) -c $$(( $(CLK_FREQ) / 1000000 )) -mtr /dev/stdout $(TOP).asc

prog: $(TOP).bin
	$(DFU_UTIL) -d 1209:b1c0 -a $(DFU_ALT_FLASH) -D $(TOP).bin -R

clean:
	$(RM) $(TOP).json $(TOP).asc $(TOP).bin
