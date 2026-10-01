# what each module instantiates; update when instantiations change
RTL_fifo                 := $(CORE_DIR)/fifo.sv
RTL_uart_rx              := $(PERIPH_DIR)/uart_rx.sv
RTL_uart_tx              := $(PERIPH_DIR)/uart_tx.sv
RTL_spi_slave            := $(PERIPH_DIR)/spi_slave.sv $(RTL_fifo)
RTL_hps_bridge           := $(PERIPH_DIR)/hps_bridge.sv

# one DEPS_<name> per tests/sv/<name>_tb.sv
DEPS_uart_rx              := $(RTL_uart_rx)
DEPS_uart_tx              := $(RTL_uart_tx)
DEPS_spi_slave            := $(RTL_spi_slave)
DEPS_hps_bridge           := $(RTL_hps_bridge)

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

# the unit benches, then the legacy peripheral benches (removed with the pico2-ice)
test: unit legacy-test

legacy-test: | $(LOG_DIR)
	@./run_tests.sh

print-tests:
	@echo $(TESTS)

.PHONY: test legacy-test print-tests $(foreach t,$(TESTS),test-$(t) build-$(t) wave-$(t))
