# instruction-stream core (DE1-SoC spec)
ISA_RTL := rtl/isa/isa_pkg.sv \
           $(CORE_DIR)/fifo.sv $(CORE_DIR)/systolic_data_setup.sv \
           rtl/isa/isa_pe.sv rtl/isa/isa_array.sv \
           rtl/isa/isa_dispatch.sv rtl/isa/isa_ld.sv rtl/isa/isa_wt.sv \
           rtl/isa/isa_mm.sv rtl/isa/isa_act.sv rtl/isa/isa_core.sv \
           $(PERIPH_DIR)/isa_bridge.sv $(HPS_DIR)/tpu_isa_top.sv

ISA_N           ?= 8
ISA_WMEM_ROWS   ?= 8192
ISA_UB_DEPTH    ?= 16384
ISA_ACC_DEPTH   ?= 1024
ISA_PARAM_DEPTH ?= 256
ISA_SIM_DIR := $(SIM_DIR)/verilator/isa_n$(ISA_N)
ISA_SIM     := $(ISA_SIM_DIR)/tb_isa

isa-model-test:
	@python3 $(TEST_DIR)/isa/test_isa_model.py

isa-sim: | $(SIM_DIR)
	@mkdir -p $(ISA_SIM_DIR)
	@$(VERILATOR) --cc --exe --build -j 0 -Wall --Mdir $(ISA_SIM_DIR) verilator.vlt \
		--top-module tpu_isa_top \
		-GN=$(ISA_N) -GWMEM_ROWS=$(ISA_WMEM_ROWS) -GUB_DEPTH=$(ISA_UB_DEPTH) \
		-GACC_DEPTH=$(ISA_ACC_DEPTH) -GPARAM_DEPTH=$(ISA_PARAM_DEPTH) \
		-CFLAGS "-std=c++17 -DTB_N=$(ISA_N) -DTB_WMEM_ROWS=$(ISA_WMEM_ROWS) \
		         -DTB_UB_DEPTH=$(ISA_UB_DEPTH) -DTB_ACC_DEPTH=$(ISA_ACC_DEPTH) \
		         -DTB_PARAM_DEPTH=$(ISA_PARAM_DEPTH)" \
		$(ISA_RTL) $(TEST_DIR)/verilator/tb_isa.cpp -o tb_isa > /dev/null
	@echo "isa-sim: $(ISA_SIM) (N=$(ISA_N))"

isa-rtl-test: isa-sim
	@python3 $(TEST_DIR)/isa/test_isa_rtl.py $(ISA_SIM)

isa-test: isa-model-test
	@$(MAKE) --no-print-directory isa-rtl-test ISA_N=8
	@$(MAKE) --no-print-directory isa-rtl-test ISA_N=4

isa-lint:
	@$(VERILATOR) --lint-only -Wall --timing -sv verilator.vlt $(ISA_RTL) --top-module tpu_isa_top
	@echo "isa-lint: clean"

.PHONY: isa-model-test isa-sim isa-rtl-test isa-test isa-lint

# DE1-SoC FPGA-only self-test (boards/de1soc/fpga/selftest): the ROM transcript
# replayed through the real bridge, exactly as the bitstream will run it
ISA_ST_DIR := boards/de1soc/fpga/selftest
ISA_ST_ROM := $(ISA_ST_DIR)/isa_selftest.hex
ISA_ST_HEX ?= $(ISA_ST_ROM)
ISA_ST_SIM := $(SIM_DIR)/verilator/isa_selftest_n$(ISA_N)/tb_isa_selftest
ISA_ST_SLOTS ?= 0

isa-selftest-rom:
	@python3 $(ISA_ST_DIR)/gen_selftest.py $(ISA_ST_ROM) --n $(ISA_N)

isa-selftest-sim: isa-selftest-rom | $(SIM_DIR)
	@mkdir -p $(dir $(ISA_ST_SIM))
	@$(VERILATOR) --cc --exe --build -j 0 -Wall --Mdir $(dir $(ISA_ST_SIM)) verilator.vlt \
		--top-module tpu_isa_selftest -GN=$(ISA_N) -GROM_FILE='"$(abspath $(ISA_ST_HEX))"' \
		-CFLAGS -std=c++17 $(ISA_RTL) $(HPS_DIR)/isa_replay.sv $(HPS_DIR)/tpu_isa_selftest.sv \
		$(TEST_DIR)/verilator/tb_isa_selftest.cpp -o tb_isa_selftest > /dev/null
	@$(ISA_ST_SIM) $(ISA_ST_SLOTS)

.PHONY: isa-selftest-rom isa-selftest-sim
