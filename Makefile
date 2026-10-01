# simulation, lint and hardware-test entry point; rules live in mk/, see `make list`

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

# yosys's own SB_MAC16 model, so pe_pair simulates against what synthesis maps to
# extracted because verilator rejects other constructs in cells_sim.v
CELLS_SIM    := $(shell yosys-config --datdir)/ice40/cells_sim.v
SB_MAC16_SIM := $(SIM_DIR)/sb_mac16_sim.v

$(SB_MAC16_SIM): $(CELLS_SIM) | $(SIM_DIR)
	echo '`timescale 1ns / 1ps' > $@
	sed -n '/^module SB_MAC16/,/^endmodule/p' $< >> $@
	@grep -q endmodule $@ || { echo "SB_MAC16 extraction from $< failed"; rm -f $@; exit 1; }

# tpu_pkg.sv first: the sequencer imports it
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
	@echo "  make check-protocol | make verilate-test | make sim-bridge |"
	@echo "  make hw-test PORT=... [CONFIG=<name>] | make host-flags CONFIG=<name> | make clean"

clean:
	rm -rf $(SIM_DIR)

.PHONY: all list clean
