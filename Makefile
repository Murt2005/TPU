# simulation and lint entry point; rules live in mk/, see `make list`

# Verilator 5.052 (UVM needs it); override VERILATOR_HOME to use another install
VERILATOR_HOME ?= $(HOME)/.local/verilator-5.052
VERILATOR      := $(VERILATOR_HOME)/bin/verilator --assert
# parallel C++ compile jobs per Verilator build; raise it (JOBS=8) when heat isn't a concern
JOBS           ?= 4

RTL_DIR      := rtl
COMMON_DIR   := $(RTL_DIR)/common
DATAPATH_DIR := $(RTL_DIR)/datapath
CONTROL_DIR  := $(RTL_DIR)/control
PERIPH_DIR   := $(RTL_DIR)/peripherals
HPS_DIR    := boards/de1soc/top
TEST_DIR   := tests
SIM_DIR    := sim

# the core, in compile order: tpu_pkg first (everything imports it)
CORE_RTL := $(COMMON_DIR)/tpu-pkg.sv $(COMMON_DIR)/fifo.sv $(COMMON_DIR)/block-fifo.sv \
            $(DATAPATH_DIR)/systolic-data-setup.sv $(DATAPATH_DIR)/pe.sv $(DATAPATH_DIR)/mmu.sv \
            $(DATAPATH_DIR)/weight-fifo.sv $(DATAPATH_DIR)/unified-buffer.sv $(DATAPATH_DIR)/accumulator.sv \
            $(DATAPATH_DIR)/bias.sv $(DATAPATH_DIR)/activation.sv \
            $(CONTROL_DIR)/dispatch.sv $(CONTROL_DIR)/load-engine.sv $(CONTROL_DIR)/weight-engine.sv \
            $(CONTROL_DIR)/matmul-engine.sv $(CONTROL_DIR)/activate-engine.sv $(CONTROL_DIR)/ddr-reader.sv $(CONTROL_DIR)/ddr-writer.sv $(CONTROL_DIR)/memory-arbiter.sv \
            $(RTL_DIR)/tpu-core.sv $(PERIPH_DIR)/host-bridge.sv $(HPS_DIR)/tpu-top.sv

all: test

$(SIM_DIR):
	@mkdir -p $@

include mk/verilator.mk
include mk/core.mk
include mk/uvm.mk

# the fast loop
test: uvm
	@$(MAKE) --no-print-directory uvm-top N=8
	@$(MAKE) --no-print-directory uvm-top N=4

# every gate short of a board
check: lint test sim-test selftest-sim

list:
	@echo "make test         the UVM tests (tests/uvm): every block, then tpu_top at N = 8 and 4"
	@echo "  make uvm | make uvm-top [N=4]"
	@for t in $(UVM_BLOCK_TESTS); do echo "  make uvm-$$t"; done
	@echo "make sim-test     reference-model checks, then the RTL vs the model at N = 8 and 4"
	@echo "  make model-test | make rtl-test [N=4] | make rtl-sim [N=4]"
	@echo "make selftest-sim the DE1-SoC self-test ROM in Verilator [ST_SLOTS=21]"
	@echo "make ddr-probe-sim the DE1-SoC DDR3 bandwidth probe against a model of the FPGA-to-SDRAM port"
	@echo "make viz          a workload's cycle-by-cycle page from the traced Verilator model"
	@echo "  make viz [N=4] [WORKLOAD=mlp|matmul|mnist] [VIZ_ARGS='--batches 2']"
	@echo "make lint         verilator lint: tpu_top at N = 8 and 4, tpu_selftest"
	@echo "make check        all of the above"
	@echo "make clean"

clean:
	rm -rf $(SIM_DIR)

.PHONY: all test check list clean
