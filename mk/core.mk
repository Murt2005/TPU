# the core against its reference model, and the DE1-SoC self-test in simulation
# (CORE_RTL is in the Makefile). N and the memory depths pick the build
N           ?= 8
WMEM_ROWS   ?= 8192
UB_DEPTH    ?= 16384
ACC_DEPTH   ?= 1024
PARAM_DEPTH ?= 256
RTL_SIM_DIR := $(SIM_DIR)/verilator/core_n$(N)
RTL_SIM     := $(RTL_SIM_DIR)/tb_isa

# the reference model against independent references (tpu.golden, the host MNIST path)
model-test:
	@python3 $(TEST_DIR)/isa/test_isa_model.py

# tpu_top as a register-level transport for host/tpu/isa_device.py
rtl-sim: | $(SIM_DIR)
	@mkdir -p $(RTL_SIM_DIR)
	@$(VERILATOR) --cc --exe --build -j $(JOBS) -Wall --Mdir $(RTL_SIM_DIR) verilator.vlt \
		--top-module tpu_top \
		-GARRAY_SIZE=$(N) -GWMEM_ROWS=$(WMEM_ROWS) -GUB_DEPTH=$(UB_DEPTH) \
		-GACC_DEPTH=$(ACC_DEPTH) -GPARAMETER_DEPTH=$(PARAM_DEPTH) \
		-CFLAGS "-std=c++17 -DTB_N=$(N) -DTB_WMEM_ROWS=$(WMEM_ROWS) \
		         -DTB_UB_DEPTH=$(UB_DEPTH) -DTB_ACC_DEPTH=$(ACC_DEPTH) \
		         -DTB_PARAM_DEPTH=$(PARAM_DEPTH)" \
		$(CORE_RTL) $(TEST_DIR)/verilator/tb-isa.cpp -o tb_isa > /dev/null
	@echo "rtl-sim: $(RTL_SIM) (N=$(N))"

# the RTL against the model, word for word
rtl-test: rtl-sim
	@python3 $(TEST_DIR)/isa/test_isa_rtl.py $(RTL_SIM)

sim-test: model-test
	@$(MAKE) --no-print-directory rtl-test N=8
	@$(MAKE) --no-print-directory rtl-test N=4

# DE1-SoC FPGA-only self-test (boards/de1soc/fpga/selftest): the ROM transcript
# replayed through the real bridge, exactly as the bitstream will run it.
# ST_SLOTS=21 also reads the perf-counter captures back off the HEX displays
ST_DIR   := boards/de1soc/fpga/selftest
ST_ROM   := $(ST_DIR)/isa_selftest.hex
# the board's ROM is the N = 8 one; other sizes get their own file so they can't overwrite it
ST_HEX   ?= $(if $(filter 8,$(N)),$(ST_ROM),$(SIM_DIR)/verilator/selftest_n$(N)/isa_selftest.hex)
ST_SIM   := $(SIM_DIR)/verilator/selftest_n$(N)/tb_isa_selftest
ST_SLOTS ?= 0

selftest-rom:
	@mkdir -p $(dir $(ST_HEX))
	@python3 $(ST_DIR)/gen_selftest.py $(ST_HEX) --n $(N)

selftest-sim: selftest-rom | $(SIM_DIR)
	@mkdir -p $(dir $(ST_SIM))
	@$(VERILATOR) --cc --exe --build -j $(JOBS) -Wall --Mdir $(dir $(ST_SIM)) verilator.vlt \
		--top-module tpu_selftest -GARRAY_SIZE=$(N) -GROM_FILE='"$(abspath $(ST_HEX))"' \
		-CFLAGS -std=c++17 $(CORE_RTL) $(HPS_DIR)/replay.sv $(HPS_DIR)/tpu-selftest.sv \
		$(TEST_DIR)/verilator/tb-isa-selftest.cpp -o tb_isa_selftest > /dev/null
	@$(ST_SIM) $(ST_SLOTS)

.PHONY: model-test rtl-sim rtl-test sim-test selftest-rom selftest-sim
