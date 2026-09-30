## ============================================================================
##  TPU — simulation, lint, and hardware-test automation
##
##  Usage:
##    make              Build + run every testbench, print a pass/fail summary
##    make test         Same as above
##    make test-fifo    Build + run a single testbench (tests/sv/fifo_tb.sv)
##    make build-fifo   Compile a single testbench without running it
##    make wave-fifo    Run a testbench and open its VCD in gtkwave (if dumped)
##    make lint         Protocol-constant check + Verilator lint, 4 configurations
##    make check-protocol  Just the protocol-constant check
##    make verilate-test  Full-chip Verilator bench, 12 shape/PHY/width combos
##    make sim-bridge   Build the Verilator model as a --link sim transport
##    make list         Show all available test targets
##    make clean        Remove all simulation build artifacts
##    make hw-test PORT=/dev/cu.usbmodemXXXX   Run tests/hw/hw_regression.py on a board
##
##  The rules live in mk/: sim.mk (testbenches), verilator.mk (lint, full-chip
##  sim, sim bridge), hw.mk (hardware regression). FPGA builds are per board:
##  boards/pico2-ice/fpga/, boards/de1soc/fpga/.
## ============================================================================

IVERILOG  := iverilog
VVP       := vvp
GTKWAVE   := gtkwave
VERILATOR := verilator
IFLAGS    := -g2012 -Wall

CORE_DIR   := rtl/core
PERIPH_DIR := rtl/peripherals
PICO_DIR   := boards/pico2-ice/top
HPS_DIR    := boards/de1soc/top
TEST_DIR   := tests
TB_DIR     := $(TEST_DIR)/sv
SIM_DIR    := sim
LOG_DIR    := $(SIM_DIR)/logs

# pe_pair hand-instantiates SB_MAC16, so simulations of it compile yosys's
# own SB_MAC16 model — the same model synthesis maps to, not a stand-in.
# The module is extracted from the installed cells_sim.v at build time
# (single source of truth) because Verilator's -sv mode rejects unrelated
# constructs elsewhere in that file (SB_RAM40_4K* port-default syntax).
CELLS_SIM    := $(shell yosys-config --datdir)/ice40/cells_sim.v
SB_MAC16_SIM := $(SIM_DIR)/sb_mac16_sim.v

$(SB_MAC16_SIM): $(CELLS_SIM) | $(SIM_DIR)
	echo '`timescale 1ns / 1ps' > $@
	sed -n '/^module SB_MAC16/,/^endmodule/p' $< >> $@
	@grep -q endmodule $@ || { echo "SB_MAC16 extraction from $< failed"; rm -f $@; exit 1; }

# Whole-design file sets. tpu_pkg.sv leads: it must be read before the
# sequencer that imports it.
SHARED_RTL := $(CORE_DIR)/tpu_pkg.sv \
              $(filter-out $(CORE_DIR)/tpu_pkg.sv,$(wildcard $(CORE_DIR)/*.sv)) \
              $(wildcard $(PERIPH_DIR)/*.sv)
PICO_RTL   := $(SB_MAC16_SIM) $(SHARED_RTL) $(wildcard $(PICO_DIR)/*.sv)
HPS_RTL    := $(SHARED_RTL) $(wildcard $(HPS_DIR)/*.sv)

all: test

$(SIM_DIR) $(LOG_DIR):
	@mkdir -p $@

include mk/sim.mk
include mk/verilator.mk
include mk/hw.mk

list:
	@echo "Available tests (tests/sv/<name>_tb.sv):"
	@for t in $(TESTS); do echo "  make test-$$t"; done
	@echo ""
	@echo "Other targets: make test | make build-<name> | make wave-<name> | make lint |"
	@echo "  make verilate-test | make sim-bridge | make hw-test PORT=... | make clean"

clean:
	rm -rf $(SIM_DIR)

.PHONY: all list clean
