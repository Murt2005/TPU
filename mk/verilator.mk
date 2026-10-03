# lint: the core at both verified sizes, the self-test top as Quartus sees it, the DDR3 probe
lint:
	$(VERILATOR) --lint-only -Wall --timing -sv verilator.vlt \
		$(CORE_RTL) --top-module tpu_top
	$(VERILATOR) --lint-only -Wall --timing -sv verilator.vlt \
		-GARRAY_SIZE=4 $(CORE_RTL) --top-module tpu_top
	$(VERILATOR) --lint-only -Wall --timing -sv verilator.vlt \
		-GWEIGHT_LANES=4 -GDDR_BEAT_BITS=256 $(CORE_RTL) --top-module tpu_top
	$(VERILATOR) --lint-only -Wall -sv verilator.vlt -GBEAT_BITS=256 $(HPS_DIR)/ddr-probe.sv --top-module ddr_probe
	$(VERILATOR) --lint-only -Wall --timing -sv verilator.vlt \
		$(CORE_RTL) $(HPS_DIR)/replay.sv $(HPS_DIR)/tpu-selftest.sv --top-module tpu_selftest
	$(VERILATOR) --lint-only -Wall -sv verilator.vlt $(HPS_DIR)/ddr-probe.sv --top-module ddr_probe
	@echo "lint: clean (tpu_top at N = 8 and 4 and 256-bit DDR3, tpu_selftest, ddr_probe at 128 and 256)"

.PHONY: lint
