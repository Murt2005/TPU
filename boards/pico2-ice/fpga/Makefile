# pico2-ice bitstream: yosys -> nextpnr-ice40 -> icepack -> dfu-util
# targets and knobs: docs/pico2-ice.md §2; named configs: make CONFIG=<name>

YOSYS    := yosys
NEXTPNR  := nextpnr-ice40
ICEPACK  := icepack
ICETIME  := icetime
DFU_UTIL := dfu-util

CORE_DIR   := ../../../rtl/core
PERIPH_DIR := ../../../rtl/peripherals
TOP_DIR    := ../top
TOP     := tpu_top

# before the ?= defaults so a config's values win
PICO_CONFIG_DIR := ../configs
include ../config.mk
PCF     := tpu_top.pcf

# no crystal: must match the clock the firmware requests in ice_fpga_init()
CLK_FREQ ?= 12000000

# 1M divides 12 MHz exactly; must match the host's DEFAULT_BAUD
BAUD_RATE ?= 1000000

# tpu_top's FIFO_DEPTH default of 4 caps ARRAY_ROWS and M_TILE at 4
ARRAY_ROWS ?= 2
NUM_COLS   ?= 2
M_TILE     ?= $(ARRAY_ROWS)

PSUM_WIDTH ?= 16

USE_SPI ?= 0

# no -dsp with pe_pair: it must not remap the hand-placed SB_MAC16s
USE_MAC16_PAIR ?= 0
DSP_FLAG := $(if $(filter-out 0,$(USE_MAC16_PAIR)),,-dsp)

# -dff sweeps the sequencer's duplicated staging regs: what lets 4x4/M_TILE=4 fit
ABC_FLAGS := -abc9 -dff

# DFU alt setting for the flash image, as in pico-ice-sdk's examples
DFU_ALT_FLASH := 0

RTL := $(CORE_DIR)/tpu_pkg.sv \
       $(PERIPH_DIR)/uart_rx.sv \
       $(PERIPH_DIR)/uart_tx.sv \
       $(PERIPH_DIR)/spi_slave.sv \
       $(CORE_DIR)/tpu_sequencer.sv \
       $(CORE_DIR)/unified_buffer.sv \
       $(CORE_DIR)/weight_fifo.sv \
       $(CORE_DIR)/fifo.sv \
       $(CORE_DIR)/systolic_data_setup.sv \
       $(CORE_DIR)/mmu.sv \
       $(CORE_DIR)/pe.sv \
       $(TOP_DIR)/pe_pair.sv \
       $(CORE_DIR)/accumulator.sv \
       $(CORE_DIR)/bias.sv \
       $(CORE_DIR)/activation.sv \
       $(CORE_DIR)/tpu_core.sv \
       $(TOP_DIR)/tpu_top.sv

.PHONY: all json asc bin stat util time prog clean show-config FORCE

# stamp of every netlist knob, so changing CONFIG rebuilds instead of reusing a stale .bin
KNOBS := CLK_FREQ=$(CLK_FREQ) BAUD_RATE=$(BAUD_RATE) ARRAY_ROWS=$(ARRAY_ROWS) \
         NUM_COLS=$(NUM_COLS) M_TILE=$(M_TILE) PSUM_WIDTH=$(PSUM_WIDTH) \
         USE_SPI=$(USE_SPI) USE_MAC16_PAIR=$(USE_MAC16_PAIR) ABC_FLAGS=$(ABC_FLAGS)

.knobs: FORCE
	@echo '$(KNOBS)' | cmp -s - $@ || echo '$(KNOBS)' > $@

all: $(TOP).bin

json: $(TOP).json
asc: $(TOP).asc
bin: $(TOP).bin

$(TOP).json: $(RTL) .knobs
	$(YOSYS) -q -p "\
		read_verilog -sv $(RTL); \
		chparam -set CLK_FREQ $(CLK_FREQ) $(TOP); \
		chparam -set BAUD_RATE $(BAUD_RATE) $(TOP); \
		chparam -set ARRAY_ROWS $(ARRAY_ROWS) $(TOP); \
		chparam -set NUM_COLS $(NUM_COLS) $(TOP); \
		chparam -set M_TILE $(M_TILE) $(TOP); \
		chparam -set PSUM_WIDTH $(PSUM_WIDTH) $(TOP); \
		chparam -set USE_SPI $(USE_SPI) $(TOP); \
		chparam -set USE_MAC16_PAIR $(USE_MAC16_PAIR) $(TOP); \
		synth_ice40 -top $(TOP) $(DSP_FLAG) $(ABC_FLAGS) -json $@"

$(TOP).asc: $(TOP).json $(PCF)
	$(NEXTPNR) -q --up5k --package sg48 --pcf $(PCF) --json $(TOP).json --asc $@

$(TOP).bin: $(TOP).asc
	$(ICEPACK) $< $@

stat: $(RTL)
	@$(YOSYS) -p "\
		read_verilog -sv $(RTL); \
		chparam -set CLK_FREQ $(CLK_FREQ) $(TOP); \
		chparam -set BAUD_RATE $(BAUD_RATE) $(TOP); \
		chparam -set ARRAY_ROWS $(ARRAY_ROWS) $(TOP); \
		chparam -set NUM_COLS $(NUM_COLS) $(TOP); \
		chparam -set M_TILE $(M_TILE) $(TOP); \
		chparam -set PSUM_WIDTH $(PSUM_WIDTH) $(TOP); \
		chparam -set USE_SPI $(USE_SPI) $(TOP); \
		chparam -set USE_MAC16_PAIR $(USE_MAC16_PAIR) $(TOP); \
		synth_ice40 -top $(TOP) $(DSP_FLAG) $(ABC_FLAGS)" 2>&1 \
		| awk '/^=== design hierarchy ===/{exit} /^=== $(TOP) ===/{p=1} p'

util: $(TOP).json $(PCF)
	@$(NEXTPNR) --up5k --package sg48 --pcf $(PCF) --json $(TOP).json --asc $(TOP).asc 2>&1 \
		| awk '/^Info: Placed [0-9]+ cells based on constraints\.$$/{exit} /^Info: Device utilisation:/{p=1} p'

# some Homebrew icestorm installs can't resolve `-d up5k`; pass the chipdb path instead
ICETIME_CHIPDB ?=
ICETIME_DEVICE := $(if $(ICETIME_CHIPDB),-C $(ICETIME_CHIPDB),-d up5k)

time: $(TOP).asc
	$(ICETIME) $(ICETIME_DEVICE) -c $$(( $(CLK_FREQ) / 1000000 )) -mtr /dev/stdout $(TOP).asc

prog: $(TOP).bin
	$(DFU_UTIL) -d 1209:b1c0 -a $(DFU_ALT_FLASH) -D $(TOP).bin -R

show-config:
	@echo "config:     $(or $(CONFIG),(none -- defaults and command-line knobs))"
	@echo "knobs:      $(KNOBS)"
	@echo "firmware:   boards/pico2-ice/firmware/$(PICO_FIRMWARE)"
	@echo "host flags: $(PICO_HOST_FLAGS)"

clean:
	$(RM) $(TOP).json $(TOP).asc $(TOP).bin .knobs
