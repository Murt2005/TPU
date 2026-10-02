# UVM environments (tests/uvm/), on Verilator 5.052 with the pinned uvm-verilator
# submodule. every block test is one binary; make uvm-<test> runs one
UVM_DIR       := $(TEST_DIR)/uvm
UVM_LIBRARY   := $(UVM_DIR)/uvm-verilator/src
UVM_SIM       := $(SIM_DIR)/uvm
UVM_BLOCKS    := $(UVM_SIM)/blocks/Vuvm_blocks_top
UVM_BLOCK_TESTS := fifo_random_test

UVM_FLAGS := --binary --timing -j 0 -Wno-fatal -Wno-lint -Wno-style -Wno-SYMRSVDWORD \
             -Wno-CONSTRAINTIGN -Wno-ZERODLY +define+UVM_NO_DPI +incdir+$(UVM_LIBRARY)
UVM_BLOCK_SOURCES := $(UVM_DIR)/common/uvm-common-pkg.sv \
                     $(UVM_DIR)/blocks/fifo/fifo-if.sv $(UVM_DIR)/blocks/fifo/fifo-pkg.sv \
                     $(UVM_DIR)/blocks/blocks-top.sv

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
uvm-$(1): $(UVM_BLOCKS)
	@$(UVM_BLOCKS) +UVM_TESTNAME=$(1) > $(UVM_SIM)/blocks/$(1).log 2>&1; \
	if grep -q 'RESULT.*$(1) PASSED' $(UVM_SIM)/blocks/$(1).log; then \
		printf '  %-28s PASS\n' $(1); \
	else \
		printf '  %-28s FAIL (%s)\n' $(1) $(UVM_SIM)/blocks/$(1).log; \
		grep -E 'UVM_(ERROR|FATAL) ' $(UVM_SIM)/blocks/$(1).log | head -5; exit 1; \
	fi
endef
$(foreach t,$(UVM_BLOCK_TESTS),$(eval $(call UVM_TEST_RULE,$(t))))

uvm: $(foreach t,$(UVM_BLOCK_TESTS),uvm-$(t))
	@echo "uvm: all $(words $(UVM_BLOCK_TESTS)) tests passed"

.PHONY: uvm $(foreach t,$(UVM_BLOCK_TESTS),uvm-$(t))
