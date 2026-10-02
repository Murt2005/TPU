# unit benches for the core (tests/unit/<name>-tb.sv holding module <name>_tb), self-checking
# via check.svh, built with verilator --binary against the core's files. make unit-<name> runs one
UNIT_DIR   := $(TEST_DIR)/unit
UNIT_TESTS := $(sort $(patsubst $(UNIT_DIR)/%-tb.sv,%,$(wildcard $(UNIT_DIR)/*-tb.sv)))
unit_top    = $(subst -,_,$(1))_tb
UNIT_SIM   := $(SIM_DIR)/unit
CORE_FILES := $(filter $(CORE_DIR)/%,$(CORE_RTL))
REQUANT_VECTORS := $(UNIT_SIM)/requant_vectors.txt

$(REQUANT_VECTORS): $(UNIT_DIR)/gen_requant.py host/tpu/golden.py | $(SIM_DIR)
	@mkdir -p $(UNIT_SIM)
	@python3 $(UNIT_DIR)/gen_requant.py $@

define UNIT_RULE
$(UNIT_SIM)/$(1)/V$(call unit_top,$(1)): $(UNIT_DIR)/$(1)-tb.sv $(UNIT_DIR)/check.svh $(CORE_FILES) | $(SIM_DIR)
	@mkdir -p $(UNIT_SIM)/$(1)
	@$(VERILATOR) --binary --timing -j 0 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
		-I$(UNIT_DIR) --Mdir $(UNIT_SIM)/$(1) --top-module $(call unit_top,$(1)) \
		$(CORE_FILES) $(UNIT_DIR)/$(1)-tb.sv > $(UNIT_SIM)/$(1)/build.log 2>&1 \
		|| { cat $(UNIT_SIM)/$(1)/build.log; exit 1; }

unit-$(1): $(UNIT_SIM)/$(1)/V$(call unit_top,$(1)) $(if $(filter activation,$(1)),$(REQUANT_VECTORS))
	@$(UNIT_SIM)/$(1)/V$(call unit_top,$(1)) +vectors=$(abspath $(REQUANT_VECTORS))
endef
$(foreach t,$(UNIT_TESTS),$(eval $(call UNIT_RULE,$(t))))

# every bench, then a summary; fails if any did
unit: $(foreach t,$(UNIT_TESTS),$(UNIT_SIM)/$(t)/V$(call unit_top,$(t))) $(REQUANT_VECTORS)
	@fail=0; for t in $(UNIT_TESTS); do \
		if $(UNIT_SIM)/$$t/V$$(echo $$t | tr - _)_tb +vectors=$(abspath $(REQUANT_VECTORS)) > $(UNIT_SIM)/$$t/run.log 2>&1 \
		   && grep -q '^PASSED' $(UNIT_SIM)/$$t/run.log; then \
			printf '  %-24s PASS  %s\n' $$t "$$(grep -E '^[0-9]+ tests' $(UNIT_SIM)/$$t/run.log)"; \
		else \
			printf '  %-24s FAIL\n' $$t; grep -E 'FAIL|Error|error' $(UNIT_SIM)/$$t/run.log | head -5; fail=1; \
		fi; \
	done; \
	if [ $$fail = 0 ]; then echo "unit: all $(words $(UNIT_TESTS)) benches passed"; else echo "unit: FAILED"; exit 1; fi

.PHONY: unit $(foreach t,$(UNIT_TESTS),unit-$(t))
