# UVM environments (tests/uvm/), on Verilator 5.052 with the pinned uvm-verilator
# submodule. every block test is one binary; make uvm-<test> runs one
UVM_DIR       := $(TEST_DIR)/uvm
UVM_LIBRARY   := $(UVM_DIR)/uvm-verilator/src
UVM_SIM       := $(SIM_DIR)/uvm
UVM_BLOCKS    := $(UVM_SIM)/blocks/Vuvm_blocks_top
UVM_BLOCKS_LIST := fifo pe systolic-data-setup weight-fifo accumulator bias activation unified-buffer mmu
UVM_BLOCK_TESTS := fifo_random_test pe_random_test systolic_data_setup_random_test weight_fifo_random_test \
                   accumulator_random_test bias_random_test activation_test unified_buffer_random_test mmu_random_test
REQUANT_VECTORS := $(UVM_SIM)/requant_vectors.txt

UVM_FLAGS := --binary --timing -j $(JOBS) -Wno-fatal -Wno-lint -Wno-style -Wno-SYMRSVDWORD \
             -Wno-CONSTRAINTIGN -Wno-ZERODLY +define+UVM_NO_DPI +incdir+$(UVM_LIBRARY)
UVM_BLOCK_SOURCES := $(UVM_DIR)/common/uvm-common-pkg.sv \
                     $(foreach b,$(UVM_BLOCKS_LIST),$(UVM_DIR)/blocks/$(b)/$(b)-if.sv $(UVM_DIR)/blocks/$(b)/$(b)-pkg.sv) \
                     $(UVM_DIR)/blocks/blocks-top.sv

# requantizer vectors from the host reference (tpu.golden.requant), for activation_test
$(REQUANT_VECTORS): $(UVM_DIR)/blocks/activation/gen_requant.py host/tpu/golden.py | $(SIM_DIR)
	@mkdir -p $(UVM_SIM)
	@python3 $(UVM_DIR)/blocks/activation/gen_requant.py $@ > /dev/null

$(UVM_LIBRARY)/uvm_pkg.sv:
	@echo "the UVM library is a submodule: run 'git submodule update --init'" && false

$(UVM_BLOCKS): $(UVM_LIBRARY)/uvm_pkg.sv $(UVM_BLOCK_SOURCES) $(CORE_RTL) | $(SIM_DIR)
	@mkdir -p $(dir $@)
	@echo "uvm: building the block environments (~1 min)"
	@$(VERILATOR) $(UVM_FLAGS) --Mdir $(dir $@) --top-module uvm_blocks_top \
		$(UVM_LIBRARY)/uvm_pkg.sv $(filter $(RTL_DIR)/%,$(CORE_RTL)) $(UVM_BLOCK_SOURCES) \
		> $(dir $@)build.log 2>&1 || { grep -E '%Error' $(dir $@)build.log | head -20; exit 1; }

# a test passes when it prints PASSED and UVM reports no errors or fatals
define UVM_TEST_RULE
uvm-$(1): $(UVM_BLOCKS) $(REQUANT_VECTORS)
	@$(UVM_BLOCKS) +UVM_TESTNAME=$(1) +vectors=$(abspath $(REQUANT_VECTORS)) > $(UVM_SIM)/blocks/$(1).log 2>&1; \
	if grep -q 'RESULT.*$(1) PASSED' $(UVM_SIM)/blocks/$(1).log; then \
		printf '  %-34s PASS\n' $(1); \
	else \
		printf '  %-34s FAIL (%s)\n' $(1) $(UVM_SIM)/blocks/$(1).log; \
		grep -E 'UVM_(ERROR|FATAL) ' $(UVM_SIM)/blocks/$(1).log | head -5; exit 1; \
	fi
endef
$(foreach t,$(UVM_BLOCK_TESTS),$(eval $(call UVM_TEST_RULE,$(t))))

uvm: $(foreach t,$(UVM_BLOCK_TESTS),uvm-$(t))
	@echo "uvm: all $(words $(UVM_BLOCK_TESTS)) tests passed"

.PHONY: uvm $(foreach t,$(UVM_BLOCK_TESTS),uvm-$(t))

# tpu_top through its Avalon slave, against gen_cases.py's expected words; N=8 by default
UVM_TOP       := $(UVM_SIM)/top_n$(N)/Vuvm_tpu_top
UVM_TOP_CASES := $(UVM_SIM)/cases_n$(N).txt
UVM_TOP_SOURCES := $(UVM_DIR)/common/uvm-common-pkg.sv $(UVM_DIR)/top/tpu-top-if.sv \
                   $(UVM_DIR)/top/tpu-top-pkg.sv $(UVM_DIR)/top/uvm-tpu-top.sv

$(UVM_TOP_CASES): $(UVM_DIR)/top/gen_cases.py $(wildcard host/tpu/*.py) tests/isa/isa_progs.py tests/isa/test_isa_rtl.py | $(SIM_DIR)
	@mkdir -p $(UVM_SIM)
	@python3 $(UVM_DIR)/top/gen_cases.py $@ --n $(N) > /dev/null

$(UVM_TOP): $(UVM_LIBRARY)/uvm_pkg.sv $(UVM_TOP_SOURCES) $(CORE_RTL) | $(SIM_DIR)
	@mkdir -p $(dir $@)
	@echo "uvm: building the tpu_top environment at N=$(N) (~2 min)"
	@$(VERILATOR) $(UVM_FLAGS) --Mdir $(dir $@) --top-module uvm_tpu_top -GARRAY_SIZE=$(N) \
		$(UVM_LIBRARY)/uvm_pkg.sv $(CORE_RTL) $(UVM_TOP_SOURCES) \
		> $(dir $@)build.log 2>&1 || { grep -E '%Error' $(dir $@)build.log | head -20; exit 1; }

uvm-top: $(UVM_TOP) $(UVM_TOP_CASES)
	@$(UVM_TOP) +cases=$(abspath $(UVM_TOP_CASES)) > $(UVM_SIM)/tpu_top_test_n$(N).log 2>&1; \
	if grep -q 'RESULT.*tpu_top_test PASSED' $(UVM_SIM)/tpu_top_test_n$(N).log; then \
		printf '  %-34s PASS  %s\n' "tpu_top_test (N=$(N))" "$$(grep -oE '[0-9]+ cases, [0-9]+ OUT words checked' $(UVM_SIM)/tpu_top_test_n$(N).log)"; \
	else \
		printf '  %-34s FAIL (%s)\n' "tpu_top_test (N=$(N))" $(UVM_SIM)/tpu_top_test_n$(N).log; \
		grep -E 'UVM_(ERROR|FATAL) ' $(UVM_SIM)/tpu_top_test_n$(N).log | head -5; exit 1; \
	fi

.PHONY: uvm-top
