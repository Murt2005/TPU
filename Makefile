# simulation and lint entry point; rules live in mk/, see `make list`

VERILATOR := verilator --assert

CORE_DIR   := rtl/core
PERIPH_DIR := rtl/peripherals
HPS_DIR    := boards/de1soc/top
TEST_DIR   := tests
SIM_DIR    := sim

# the core, in compile order: tpu_pkg first (everything imports it)
CORE_RTL := $(CORE_DIR)/tpu-pkg.sv $(CORE_DIR)/fifo.sv $(CORE_DIR)/systolic-data-setup.sv \
            $(CORE_DIR)/pe.sv $(CORE_DIR)/mmu.sv $(CORE_DIR)/weight-fifo.sv \
            $(CORE_DIR)/unified-buffer.sv $(CORE_DIR)/accumulator.sv $(CORE_DIR)/bias.sv \
            $(CORE_DIR)/activation.sv $(CORE_DIR)/dispatch.sv $(CORE_DIR)/load-engine.sv \
            $(CORE_DIR)/weight-engine.sv $(CORE_DIR)/matmul-engine.sv $(CORE_DIR)/activate-engine.sv \
            $(CORE_DIR)/tpu-core.sv $(PERIPH_DIR)/host-bridge.sv $(HPS_DIR)/tpu-top.sv

all: test

$(SIM_DIR):
	@mkdir -p $@

include mk/verilator.mk
include mk/core.mk
include mk/unit.mk

# the fast loop
test: unit

# every gate short of a board
check: lint test sim-test selftest-sim

list:
	@echo "make test         the unit benches (tests/unit), the fast loop"
	@for t in $(UNIT_TESTS); do echo "  make unit-$$t"; done
	@echo "make sim-test     reference-model checks, then the RTL vs the model at N = 8 and 4"
	@echo "  make model-test | make rtl-test [N=4] | make rtl-sim [N=4]"
	@echo "make selftest-sim the DE1-SoC self-test ROM in Verilator [ST_SLOTS=21]"
	@echo "make lint         verilator lint: tpu_top at N = 8 and 4, tpu_selftest"
	@echo "make check        all of the above"
	@echo "make clean"

clean:
	rm -rf $(SIM_DIR)

.PHONY: all test check list clean
