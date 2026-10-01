# what each module instantiates; update when instantiations change
RTL_fifo                 := $(CORE_DIR)/fifo.sv
RTL_pe                   := $(CORE_DIR)/pe.sv
RTL_pe_pair              := $(PICO_DIR)/pe_pair.sv $(SB_MAC16_SIM)
RTL_mmu                  := $(CORE_DIR)/mmu.sv $(RTL_pe)
RTL_accumulator          := $(CORE_DIR)/accumulator.sv $(RTL_fifo)
RTL_systolic_data_setup  := $(CORE_DIR)/systolic_data_setup.sv
RTL_weight_fifo          := $(CORE_DIR)/weight_fifo.sv $(RTL_fifo)
RTL_bias                 := $(CORE_DIR)/bias.sv
RTL_activation           := $(CORE_DIR)/activation.sv
RTL_unified_buffer       := $(CORE_DIR)/unified_buffer.sv
RTL_uart_rx              := $(PERIPH_DIR)/uart_rx.sv
RTL_uart_tx              := $(PERIPH_DIR)/uart_tx.sv
RTL_spi_slave            := $(PERIPH_DIR)/spi_slave.sv $(RTL_fifo)
RTL_hps_bridge           := $(PERIPH_DIR)/hps_bridge.sv
# tpu_pkg.sv first: the sequencer imports it
RTL_pkg                  := $(CORE_DIR)/tpu_pkg.sv
RTL_tpu_sequencer        := $(RTL_pkg) $(CORE_DIR)/tpu_sequencer.sv

RTL_tpu_datapath         := $(RTL_unified_buffer) $(RTL_weight_fifo) \
                            $(RTL_systolic_data_setup) $(RTL_mmu) \
                            $(RTL_accumulator) $(RTL_bias) $(RTL_activation)

# one DEPS_<name> per tests/sv/<name>_tb.sv
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
DEPS_hps_bridge           := $(RTL_hps_bridge)
DEPS_tpu_sequencer        := $(RTL_tpu_sequencer) $(RTL_tpu_datapath)
DEPS_tpu_sequencer_4x2    := $(RTL_tpu_sequencer) $(RTL_tpu_datapath)
DEPS_tpu_sequencer_2x4    := $(RTL_tpu_sequencer) $(RTL_tpu_datapath)
# the 4x4 bench uses pe_pair
DEPS_tpu_sequencer_4x4    := $(RTL_tpu_sequencer) $(RTL_tpu_datapath) $(RTL_pe_pair)

# the test list is the files on disk; a bench without a DEPS_ line stops the build
TESTS := $(sort $(patsubst $(TB_DIR)/%_tb.sv,%,$(wildcard $(TB_DIR)/*_tb.sv)))
MISSING_DEPS := $(strip $(foreach t,$(TESTS),$(if $(DEPS_$(t)),,$(t))))
ifneq ($(MISSING_DEPS),)
$(error Testbench(es) without a DEPS_<name> line in the Makefile: $(MISSING_DEPS))
endif

dedup = $(if $1,$(firstword $1) $(call dedup,$(filter-out $(firstword $1),$1)))

.SECONDEXPANSION:
$(SIM_DIR)/%.vvp: $(TB_DIR)/%_tb.sv $$(call dedup,$$(DEPS_$$*)) | $(SIM_DIR)
	$(IVERILOG) $(IFLAGS) -o $@ $(call dedup,$(DEPS_$*)) $<

$(foreach t,$(TESTS),$(eval build-$(t): $(SIM_DIR)/$(t).vvp))

define RUN_RULE
test-$(1): $(SIM_DIR)/$(1).vvp | $(LOG_DIR)
	@cd $(SIM_DIR) && $(VVP) $(1).vvp | tee logs/$(1).log

wave-$(1): test-$(1)
	@if [ -f $(SIM_DIR)/*.vcd ]; then $(GTKWAVE) $(SIM_DIR)/*.vcd & else echo "No VCD dump found for $(1)"; fi
endef
$(foreach t,$(TESTS),$(eval $(call RUN_RULE,$(t))))

test: | $(LOG_DIR)
	@./run_tests.sh

print-tests:
	@echo $(TESTS)

.PHONY: test print-tests $(foreach t,$(TESTS),test-$(t) build-$(t) wave-$(t))
