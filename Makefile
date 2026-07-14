## ============================================================================
##  TPU RTL Test Automation
##
##  Usage:
##    make              Build + run every testbench, print a pass/fail summary
##    make test         Same as above
##    make test-fifo    Build + run a single testbench (see TESTS list below)
##    make build-fifo   Compile a single testbench without running it
##    make wave-fifo    Run a testbench and open its VCD in gtkwave (if dumped)
##    make list         Show all available test targets
##    make clean        Remove all simulation build artifacts
##    make hw-test PORT=/dev/cu.usbmodemXXXX   Run tests/hw_regression.py against real hardware
## ============================================================================

IVERILOG  := iverilog
VVP       := vvp
GTKWAVE   := gtkwave
VERILATOR := verilator
IFLAGS    := -g2012 -Wall

RTL_DIR  := rtl
TEST_DIR := tests
SIM_DIR  := sim
LOG_DIR  := $(SIM_DIR)/logs

# ----------------------------------------------------------------------------
# RTL dependency graph
#
# Reflects what each module instantiates internally:
#   mmu.sv              -> pe.sv            (instantiates 4x pe)
#   accumulator.sv       -> fifo.sv          (instantiates fifo)
#   weight_fifo.sv       -> fifo.sv          (instantiates fifo)
#   tpu_sequencer.sv     -> no RTL deps      (datapath wired externally in tb)
#   tpu_top.sv           -> all datapath modules
#   pe.sv, fifo.sv, systolic_data_setup.sv  -> no internal deps
#   bias.sv, activation.sv                  -> no internal deps
#   uart_rx.sv, uart_tx.sv                  -> no internal deps
#
# Update these lists whenever an RTL file's internal instantiations change.
# ----------------------------------------------------------------------------
RTL_fifo                 := $(RTL_DIR)/fifo.sv
RTL_pe                   := $(RTL_DIR)/pe.sv
# pe_pair hand-instantiates SB_MAC16, so simulations of it compile yosys's
# own SB_MAC16 model — the same model synthesis maps to, not a stand-in.
# The module is extracted from the installed cells_sim.v at build time
# (single source of truth) because Verilator's -sv mode rejects unrelated
# constructs elsewhere in that file (SB_RAM40_4K* port-default syntax).
CELLS_SIM                := $(shell yosys-config --datdir)/ice40/cells_sim.v
SB_MAC16_SIM             := $(SIM_DIR)/sb_mac16_sim.v
RTL_pe_pair              := $(RTL_DIR)/pe_pair.sv $(SB_MAC16_SIM)

$(SB_MAC16_SIM): $(CELLS_SIM) | $(SIM_DIR)
	echo '`timescale 1ns / 1ps' > $@
	sed -n '/^module SB_MAC16/,/^endmodule/p' $< >> $@
	@grep -q endmodule $@ || { echo "SB_MAC16 extraction from $< failed"; rm -f $@; exit 1; }
RTL_mmu                  := $(RTL_DIR)/mmu.sv $(RTL_pe)
RTL_accumulator          := $(RTL_DIR)/accumulator.sv $(RTL_fifo)
RTL_systolic_data_setup  := $(RTL_DIR)/systolic_data_setup.sv
RTL_weight_fifo          := $(RTL_DIR)/weight_fifo.sv $(RTL_fifo)
RTL_bias                 := $(RTL_DIR)/bias.sv
RTL_activation           := $(RTL_DIR)/activation.sv
RTL_unified_buffer       := $(RTL_DIR)/unified_buffer.sv
RTL_uart_rx              := $(RTL_DIR)/uart_rx.sv
RTL_uart_tx              := $(RTL_DIR)/uart_tx.sv
RTL_spi_slave            := $(RTL_DIR)/spi_slave.sv $(RTL_fifo)
RTL_tpu_sequencer        := $(RTL_DIR)/tpu_sequencer.sv

# Full datapath (everything tpu_sequencer_tb needs to instantiate)
RTL_tpu_datapath         := $(RTL_unified_buffer) $(RTL_weight_fifo) \
                            $(RTL_systolic_data_setup) $(RTL_mmu) \
                            $(RTL_accumulator) $(RTL_bias) $(RTL_activation)

# ----------------------------------------------------------------------------
# Testbench -> RTL files required to build it
#
# Each test name below maps to tests/<name>_tb.sv automatically.
# Add a new line here (+ the matching _tb.sv file) to register a new test.
# ----------------------------------------------------------------------------
DEPS_fifo                 := $(RTL_fifo)
DEPS_pe                   := $(RTL_pe)
DEPS_pe_pair              := $(RTL_pe_pair) $(RTL_pe)
DEPS_mmu                  := $(RTL_mmu)
DEPS_accumulator          := $(RTL_accumulator)
DEPS_systolic_data_setup  := $(RTL_systolic_data_setup)
DEPS_weight_fifo          := $(RTL_weight_fifo)
DEPS_bias                 := $(RTL_bias)
DEPS_activation           := $(RTL_activation)
DEPS_mmu_accum            := $(RTL_mmu) $(RTL_accumulator)
DEPS_accum_bias           := $(RTL_accumulator) $(RTL_bias)
DEPS_bias_activation      := $(RTL_accumulator) $(RTL_bias) $(RTL_activation)
DEPS_weight_fifo_mmu      := $(RTL_weight_fifo) $(RTL_mmu)
DEPS_unified_buffer       := $(RTL_unified_buffer)
DEPS_tpu_core             := $(RTL_tpu_datapath)
DEPS_uart_rx              := $(RTL_uart_rx)
DEPS_uart_tx              := $(RTL_uart_tx)
DEPS_spi_slave            := $(RTL_spi_slave)
DEPS_tpu_sequencer        := $(RTL_tpu_sequencer) $(RTL_tpu_datapath)
DEPS_tpu_sequencer_4x2    := $(RTL_tpu_sequencer) $(RTL_tpu_datapath)
DEPS_tpu_sequencer_2x4    := $(RTL_tpu_sequencer) $(RTL_tpu_datapath)

TESTS := fifo pe pe_pair mmu accumulator systolic_data_setup weight_fifo bias activation \
         unified_buffer \
         mmu_accum accum_bias bias_activation weight_fifo_mmu tpu_core \
         uart_rx uart_tx spi_slave tpu_sequencer tpu_sequencer_4x2 tpu_sequencer_2x4

# de-duplicate dep lists (modules shared via multiple paths, e.g. tpu_core -> fifo.sv)
dedup = $(if $1,$(firstword $1) $(call dedup,$(filter-out $(firstword $1),$1)))

.PHONY: all test lint verilate-test list clean hw-test $(foreach t,$(TESTS),test-$(t) build-$(t) wave-$(t))

all: test

$(SIM_DIR) $(LOG_DIR):
	@mkdir -p $@

# ----------------------------------------------------------------------------
# Per-test build + run rules (explicit, one per testbench)
# ----------------------------------------------------------------------------
build-unified_buffer:       $(SIM_DIR)/unified_buffer.vvp
build-fifo:                 $(SIM_DIR)/fifo.vvp
build-pe:                   $(SIM_DIR)/pe.vvp
build-pe_pair:              $(SIM_DIR)/pe_pair.vvp
build-mmu:                  $(SIM_DIR)/mmu.vvp
build-accumulator:          $(SIM_DIR)/accumulator.vvp
build-systolic_data_setup:  $(SIM_DIR)/systolic_data_setup.vvp
build-weight_fifo:          $(SIM_DIR)/weight_fifo.vvp
build-bias:                 $(SIM_DIR)/bias.vvp
build-activation:           $(SIM_DIR)/activation.vvp
build-mmu_accum:            $(SIM_DIR)/mmu_accum.vvp
build-accum_bias:           $(SIM_DIR)/accum_bias.vvp
build-bias_activation:      $(SIM_DIR)/bias_activation.vvp
build-weight_fifo_mmu:      $(SIM_DIR)/weight_fifo_mmu.vvp
build-tpu_core:             $(SIM_DIR)/tpu_core.vvp
build-uart_rx:              $(SIM_DIR)/uart_rx.vvp
build-uart_tx:              $(SIM_DIR)/uart_tx.vvp
build-spi_slave:            $(SIM_DIR)/spi_slave.vvp
build-tpu_sequencer:        $(SIM_DIR)/tpu_sequencer.vvp
build-tpu_sequencer_4x2:    $(SIM_DIR)/tpu_sequencer_4x2.vvp
build-tpu_sequencer_2x4:    $(SIM_DIR)/tpu_sequencer_2x4.vvp

$(SIM_DIR)/unified_buffer.vvp: $(TEST_DIR)/unified_buffer_tb.sv $(call dedup,$(DEPS_unified_buffer)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_unified_buffer)) $<

$(SIM_DIR)/fifo.vvp: $(TEST_DIR)/fifo_tb.sv $(call dedup,$(DEPS_fifo)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_fifo)) $<

$(SIM_DIR)/pe.vvp: $(TEST_DIR)/pe_tb.sv $(call dedup,$(DEPS_pe)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_pe)) $<

$(SIM_DIR)/pe_pair.vvp: $(TEST_DIR)/pe_pair_tb.sv $(call dedup,$(DEPS_pe_pair)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_pe_pair)) $<

$(SIM_DIR)/mmu.vvp: $(TEST_DIR)/mmu_tb.sv $(call dedup,$(DEPS_mmu)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_mmu)) $<

$(SIM_DIR)/accumulator.vvp: $(TEST_DIR)/accumulator_tb.sv $(call dedup,$(DEPS_accumulator)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_accumulator)) $<

$(SIM_DIR)/systolic_data_setup.vvp: $(TEST_DIR)/systolic_data_setup_tb.sv $(call dedup,$(DEPS_systolic_data_setup)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_systolic_data_setup)) $<

$(SIM_DIR)/weight_fifo.vvp: $(TEST_DIR)/weight_fifo_tb.sv $(call dedup,$(DEPS_weight_fifo)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_weight_fifo)) $<

$(SIM_DIR)/bias.vvp: $(TEST_DIR)/bias_tb.sv $(call dedup,$(DEPS_bias)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_bias)) $<

$(SIM_DIR)/activation.vvp: $(TEST_DIR)/activation_tb.sv $(call dedup,$(DEPS_activation)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_activation)) $<

$(SIM_DIR)/mmu_accum.vvp: $(TEST_DIR)/mmu_accum_tb.sv $(call dedup,$(DEPS_mmu_accum)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_mmu_accum)) $<

$(SIM_DIR)/accum_bias.vvp: $(TEST_DIR)/accum_bias_tb.sv $(call dedup,$(DEPS_accum_bias)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_accum_bias)) $<

$(SIM_DIR)/bias_activation.vvp: $(TEST_DIR)/bias_activation_tb.sv $(call dedup,$(DEPS_bias_activation)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_bias_activation)) $<

$(SIM_DIR)/weight_fifo_mmu.vvp: $(TEST_DIR)/weight_fifo_mmu_tb.sv $(call dedup,$(DEPS_weight_fifo_mmu)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_weight_fifo_mmu)) $<

$(SIM_DIR)/tpu_core.vvp: $(TEST_DIR)/tpu_core_tb.sv $(call dedup,$(DEPS_tpu_core)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_tpu_core)) $<

$(SIM_DIR)/uart_rx.vvp: $(TEST_DIR)/uart_rx_tb.sv $(call dedup,$(DEPS_uart_rx)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_uart_rx)) $<

$(SIM_DIR)/uart_tx.vvp: $(TEST_DIR)/uart_tx_tb.sv $(call dedup,$(DEPS_uart_tx)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_uart_tx)) $<

$(SIM_DIR)/spi_slave.vvp: $(TEST_DIR)/spi_slave_tb.sv $(call dedup,$(DEPS_spi_slave)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_spi_slave)) $<

$(SIM_DIR)/tpu_sequencer.vvp: $(TEST_DIR)/tpu_sequencer_tb.sv $(call dedup,$(DEPS_tpu_sequencer)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_tpu_sequencer)) $<

$(SIM_DIR)/tpu_sequencer_4x2.vvp: $(TEST_DIR)/tpu_sequencer_4x2_tb.sv $(call dedup,$(DEPS_tpu_sequencer_4x2)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_tpu_sequencer_4x2)) $<

$(SIM_DIR)/tpu_sequencer_2x4.vvp: $(TEST_DIR)/tpu_sequencer_2x4_tb.sv $(call dedup,$(DEPS_tpu_sequencer_2x4)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_tpu_sequencer_2x4)) $<

# `make test-<name>` builds (if stale) and runs a single testbench, dumping
# its VCD (if any) and console log into sim/
define RUN_RULE
test-$(1): $(SIM_DIR)/$(1).vvp | $(LOG_DIR)
	@cd $(SIM_DIR) && $(VVP) $(1).vvp | tee logs/$(1).log

wave-$(1): test-$(1)
	@if [ -f $(SIM_DIR)/*.vcd ]; then $(GTKWAVE) $(SIM_DIR)/*.vcd & else echo "No VCD dump found for $(1)"; fi
endef
$(foreach t,$(TESTS),$(eval $(call RUN_RULE,$(t))))

# ----------------------------------------------------------------------------
# Aggregate target: run everything, print a single pass/fail summary
# ----------------------------------------------------------------------------
test: | $(LOG_DIR)
	@./run_tests.sh

# Static lint over the whole synthesizable RTL tree (no simulation).
# Waivers live in verilator.vlt -- every entry there is an audited
# don't-care with a comment saying why. The extracted SB_MAC16 model is on
# the file list because pe_pair.sv instantiates it (whole-file waiver in
# the .vlt: it's yosys's library, not ours to lint).
lint: $(SB_MAC16_SIM)
	$(VERILATOR) --lint-only -Wall --timing -sv verilator.vlt \
		$(SB_MAC16_SIM) $(RTL_DIR)/*.sv --top-module tpu_top
	$(VERILATOR) --lint-only -Wall --timing -sv verilator.vlt \
		-GUSE_SPI=1 $(SB_MAC16_SIM) $(RTL_DIR)/*.sv --top-module tpu_top
	$(VERILATOR) --lint-only -Wall --timing -sv verilator.vlt \
		-GUSE_SPI=1 -GUSE_MAC16_PAIR=1 -GARRAY_ROWS=4 -GNUM_COLS=4 -GM_TILE=4 \
		$(SB_MAC16_SIM) $(RTL_DIR)/*.sv --top-module tpu_top
	@echo "lint: clean (UART + SPI + 4x4 MAC16-pair configs)"

# ----------------------------------------------------------------------------
# Verilator C++ full-chip testbench (tests/verilator/tb_tpu_top.cpp): drives
# tpu_top through its real host pins — UART at the hardware's 12 MHz/1 Mbaud
# ratio at three array shapes (incl. one with all three axes distinct), plus
# an SPI-PHY build (USE_SPI=1, spi_slave.sv) at the hardware 2x4 shape.
# Each variant gets its own obj dir under sim/verilator/.
# ----------------------------------------------------------------------------
VERILATE_SHAPES := 2_2_2_uart 2_4_2_uart 4_2_3_uart 2_4_2_spi  # ROWS_COLS_MTILE_PHY

verilate-test: $(SB_MAC16_SIM) | $(SIM_DIR)
	@set -e; for shape in $(VERILATE_SHAPES); do \
		rows=$${shape%%_*}; rest=$${shape#*_}; \
		cols=$${rest%%_*}; rest=$${rest#*_}; \
		mt=$${rest%%_*}; phy=$${rest#*_}; \
		objdir=$(SIM_DIR)/verilator/$${rows}x$${cols}m$${mt}_$${phy}; \
		mkdir -p $$objdir; \
		phyflags=""; phycflags=""; \
		if [ "$$phy" = "spi" ]; then \
			phyflags="-GUSE_SPI=1"; phycflags="-DTB_SPI"; \
		fi; \
		echo "=== verilate $${rows}x$${cols} M_TILE=$${mt} ($${phy}) ==="; \
		$(VERILATOR) --cc --exe --build -j 0 -Wall \
			--Mdir $$objdir verilator.vlt \
			--top-module tpu_top \
			-GCLK_FREQ=12000000 -GBAUD_RATE=1000000 \
			-GARRAY_ROWS=$$rows -GNUM_COLS=$$cols -GM_TILE=$$mt $$phyflags \
			-CFLAGS "-std=c++17 -DTB_ROWS=$$rows -DTB_COLS=$$cols -DTB_MTILE=$$mt $$phycflags" \
			$(SB_MAC16_SIM) $(RTL_DIR)/*.sv $(TEST_DIR)/verilator/tb_tpu_top.cpp \
			-o tb_tpu_top > /dev/null; \
		$$objdir/tb_tpu_top; \
	done
	@echo "verilate-test: all shapes passed"

list:
	@echo "Available tests (tests/<name>_tb.sv):"
	@for t in $(TESTS); do echo "  make test-$$t"; done
	@echo ""
	@echo "Other targets: make test | make build-<name> | make wave-<name> | make clean"

clean:
	rm -rf $(SIM_DIR)

# ----------------------------------------------------------------------------
# Real-hardware regression suite (pico2-ice) -- see tests/hw_regression.py
# ----------------------------------------------------------------------------
# ARRAY_ROWS/NUM_COLS/M_TILE must match the flashed bitstream's shape
# (fpga/Makefile's knobs of the same names); defaults match both. LINK must
# match the flashed PHY: uart, or spi (USE_SPI=1 gateware + TPU_LINK_SPI
# firmware).
ARRAY_ROWS ?= 2
NUM_COLS   ?= 2
M_TILE     ?= $(ARRAY_ROWS)
LINK       ?= uart

hw-test:
	@if [ -z "$(PORT)" ]; then \
		echo "Usage: make hw-test PORT=/dev/cu.usbmodemXXXX [ARRAY_ROWS=2 NUM_COLS=2 M_TILE=2 LINK=uart]"; exit 1; \
	fi
	python3 tests/hw_regression.py --port $(PORT) \
		--rows $(ARRAY_ROWS) --cols $(NUM_COLS) --m-tile $(M_TILE) --link $(LINK)
