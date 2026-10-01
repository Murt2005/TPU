# simulation, lint and hardware-test entry point; rules live in mk/, see `make list`

IVERILOG  := iverilog
VVP       := vvp
GTKWAVE   := gtkwave
VERILATOR := verilator
IFLAGS    := -g2012 -Wall

CORE_DIR   := rtl/core
PERIPH_DIR := rtl/peripherals
HPS_DIR    := boards/de1soc/top
TEST_DIR   := tests
TB_DIR     := $(TEST_DIR)/sv
SIM_DIR    := sim
LOG_DIR    := $(SIM_DIR)/logs

# the core, in compile order: tpu_pkg first (everything imports it)
CORE_RTL := $(CORE_DIR)/tpu_pkg.sv $(CORE_DIR)/fifo.sv $(CORE_DIR)/systolic_data_setup.sv \
            $(CORE_DIR)/pe.sv $(CORE_DIR)/mmu.sv $(CORE_DIR)/weight_fifo.sv \
            $(CORE_DIR)/unified_buffer.sv $(CORE_DIR)/accumulator.sv $(CORE_DIR)/bias.sv \
            $(CORE_DIR)/activation.sv $(CORE_DIR)/dispatch.sv $(CORE_DIR)/ld_engine.sv \
            $(CORE_DIR)/wt_engine.sv $(CORE_DIR)/mm_engine.sv $(CORE_DIR)/act_engine.sv \
            $(CORE_DIR)/tpu_core.sv $(PERIPH_DIR)/host_bridge.sv $(HPS_DIR)/tpu_top.sv

all: test

$(SIM_DIR) $(LOG_DIR):
	@mkdir -p $@

include mk/sim.mk
include mk/verilator.mk
include mk/hw.mk
include mk/isa.mk

list:
	@echo "Available tests (tests/sv/<name>_tb.sv):"
	@for t in $(TESTS); do echo "  make test-$$t"; done
	@echo ""
	@echo "Other targets: make test | make build-<name> | make wave-<name> | make lint |"
	@echo "  make isa-test | make isa-sim | make isa-selftest-rom | make isa-selftest-sim |"
	@echo "  make hw-test PORT=... [CONFIG=<name>] | make host-flags CONFIG=<name> | make clean"

clean:
	rm -rf $(SIM_DIR)

.PHONY: all list clean
