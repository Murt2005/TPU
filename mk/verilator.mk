# lint: the core at both verified sizes, and the self-test top as Quartus sees it
lint:
	$(VERILATOR) --lint-only -Wall --timing -sv verilator.vlt \
		$(CORE_RTL) --top-module tpu_top
	$(VERILATOR) --lint-only -Wall --timing -sv verilator.vlt \
		-GARRAY_SIZE=4 $(CORE_RTL) --top-module tpu_top
	$(VERILATOR) --lint-only -Wall --timing -sv verilator.vlt \
		$(CORE_RTL) $(HPS_DIR)/replay.sv $(HPS_DIR)/tpu-selftest.sv --top-module tpu_selftest
	@echo "lint: clean (tpu_top at N = 8 and 4, tpu_selftest)"

.PHONY: lint
