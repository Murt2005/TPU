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
## ============================================================================

IVERILOG := iverilog
VVP      := vvp
GTKWAVE  := gtkwave
IFLAGS   := -g2012 -Wall

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
#   pe.sv, fifo.sv, systolic_data_setup.sv  -> no internal deps
#   bias.sv, activation.sv                  -> no internal deps
#
# Update these lists whenever an RTL file's internal instantiations change.
# ----------------------------------------------------------------------------
RTL_fifo                 := $(RTL_DIR)/fifo.sv
RTL_pe                   := $(RTL_DIR)/pe.sv
RTL_mmu                  := $(RTL_DIR)/mmu.sv $(RTL_pe)
RTL_accumulator          := $(RTL_DIR)/accumulator.sv $(RTL_fifo)
RTL_systolic_data_setup  := $(RTL_DIR)/systolic_data_setup.sv
RTL_weight_fifo          := $(RTL_DIR)/weight_fifo.sv $(RTL_fifo)
RTL_bias                 := $(RTL_DIR)/bias.sv
RTL_activation           := $(RTL_DIR)/activation.sv
RTL_unified_buffer       := $(RTL_DIR)/unified_buffer.sv
RTL_weight_loader        := $(RTL_DIR)/weight_loader.sv
RTL_uart_rx              := $(RTL_DIR)/uart_rx.sv
RTL_uart_tx              := $(RTL_DIR)/uart_tx.sv

# ----------------------------------------------------------------------------
# Testbench -> RTL files required to build it
#
# Each test name below maps to tests/<name>_tb.sv automatically.
# Add a new line here (+ the matching _tb.sv file) to register a new test.
# ----------------------------------------------------------------------------
DEPS_fifo                 := $(RTL_fifo)
DEPS_pe                   := $(RTL_pe)
DEPS_mmu                  := $(RTL_mmu)
DEPS_accumulator          := $(RTL_accumulator)
DEPS_systolic_data_setup  := $(RTL_systolic_data_setup)
DEPS_weight_fifo          := $(RTL_weight_fifo)
DEPS_bias                 := $(RTL_bias)
DEPS_activation           := $(RTL_activation)
DEPS_weight_loader        := $(RTL_weight_loader)
DEPS_weight_loader_fifo   := $(RTL_weight_loader) $(RTL_weight_fifo)
DEPS_mmu_accum            := $(RTL_mmu) $(RTL_accumulator)
DEPS_accum_bias           := $(RTL_accumulator) $(RTL_bias)
DEPS_bias_activation      := $(RTL_accumulator) $(RTL_bias) $(RTL_activation)
DEPS_weight_fifo_mmu      := $(RTL_weight_fifo) $(RTL_mmu)
DEPS_unified_buffer       := $(RTL_unified_buffer)
DEPS_uart_rx              := $(RTL_uart_rx)
DEPS_uart_tx              := $(RTL_uart_tx)
DEPS_tpu_core             := $(RTL_unified_buffer) $(RTL_weight_fifo) \
                             $(RTL_systolic_data_setup) $(RTL_mmu) \
                             $(RTL_accumulator) $(RTL_bias) $(RTL_activation)

TESTS := fifo pe mmu accumulator systolic_data_setup weight_fifo bias activation \
         unified_buffer weight_loader uart_rx uart_tx \
         mmu_accum accum_bias bias_activation weight_fifo_mmu \
         weight_loader_fifo tpu_core

# de-duplicate dep lists (modules shared via multiple paths, e.g. tpu_core -> fifo.sv)
dedup = $(if $1,$(firstword $1) $(call dedup,$(filter-out $(firstword $1),$1)))

.PHONY: all test list clean $(foreach t,$(TESTS),test-$(t) build-$(t) wave-$(t))

all: test

$(SIM_DIR) $(LOG_DIR):
	@mkdir -p $@

# ----------------------------------------------------------------------------
# Per-test build + run rules (explicit, one per testbench)
# ----------------------------------------------------------------------------
build-unified_buffer:       $(SIM_DIR)/unified_buffer.vvp
build-fifo:                 $(SIM_DIR)/fifo.vvp
build-pe:                   $(SIM_DIR)/pe.vvp
build-mmu:                  $(SIM_DIR)/mmu.vvp
build-accumulator:          $(SIM_DIR)/accumulator.vvp
build-systolic_data_setup:  $(SIM_DIR)/systolic_data_setup.vvp
build-weight_fifo:          $(SIM_DIR)/weight_fifo.vvp
build-bias:                 $(SIM_DIR)/bias.vvp
build-activation:           $(SIM_DIR)/activation.vvp
build-weight_loader:        $(SIM_DIR)/weight_loader.vvp
build-weight_loader_fifo:   $(SIM_DIR)/weight_loader_fifo.vvp
build-mmu_accum:            $(SIM_DIR)/mmu_accum.vvp
build-accum_bias:           $(SIM_DIR)/accum_bias.vvp
build-bias_activation:      $(SIM_DIR)/bias_activation.vvp
build-weight_fifo_mmu:      $(SIM_DIR)/weight_fifo_mmu.vvp
build-uart_rx:              $(SIM_DIR)/uart_rx.vvp
build-uart_tx:              $(SIM_DIR)/uart_tx.vvp
build-tpu_core:             $(SIM_DIR)/tpu_core.vvp

$(SIM_DIR)/unified_buffer.vvp: $(TEST_DIR)/unified_buffer_tb.sv $(call dedup,$(DEPS_unified_buffer)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_unified_buffer)) $<

$(SIM_DIR)/fifo.vvp: $(TEST_DIR)/fifo_tb.sv $(call dedup,$(DEPS_fifo)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_fifo)) $<

$(SIM_DIR)/pe.vvp: $(TEST_DIR)/pe_tb.sv $(call dedup,$(DEPS_pe)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_pe)) $<

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

$(SIM_DIR)/weight_loader.vvp: $(TEST_DIR)/weight_loader_tb.sv $(call dedup,$(DEPS_weight_loader)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_weight_loader)) $<

$(SIM_DIR)/weight_loader_fifo.vvp: $(TEST_DIR)/weight_loader_fifo_tb.sv $(call dedup,$(DEPS_weight_loader_fifo)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_weight_loader_fifo)) $<

$(SIM_DIR)/mmu_accum.vvp: $(TEST_DIR)/mmu_accum_tb.sv $(call dedup,$(DEPS_mmu_accum)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_mmu_accum)) $<

$(SIM_DIR)/accum_bias.vvp: $(TEST_DIR)/accum_bias_tb.sv $(call dedup,$(DEPS_accum_bias)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_accum_bias)) $<

$(SIM_DIR)/bias_activation.vvp: $(TEST_DIR)/bias_activation_tb.sv $(call dedup,$(DEPS_bias_activation)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_bias_activation)) $<

$(SIM_DIR)/weight_fifo_mmu.vvp: $(TEST_DIR)/weight_fifo_mmu_tb.sv $(call dedup,$(DEPS_weight_fifo_mmu)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_weight_fifo_mmu)) $<

$(SIM_DIR)/uart_rx.vvp: $(TEST_DIR)/uart_rx_tb.sv $(call dedup,$(DEPS_uart_rx)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_uart_rx)) $<

$(SIM_DIR)/uart_tx.vvp: $(TEST_DIR)/uart_tx_tb.sv $(call dedup,$(DEPS_uart_tx)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_uart_tx)) $<

$(SIM_DIR)/tpu_core.vvp: $(TEST_DIR)/tpu_core_tb.sv $(call dedup,$(DEPS_tpu_core)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_tpu_core)) $<

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

list:
	@echo "Available tests (tests/<name>_tb.sv):"
	@for t in $(TESTS); do echo "  make test-$$t"; done
	@echo ""
	@echo "Other targets: make test | make build-<name> | make wave-<name> | make clean"

clean:
	rm -rf $(SIM_DIR)
