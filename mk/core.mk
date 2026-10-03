# the core against its reference model, and the DE1-SoC self-test in simulation
# (CORE_RTL is in the Makefile). N and the memory depths pick the build
N           ?= 8
WMEM_ROWS   ?= 8192
UB_DEPTH    ?= 16384
ACC_DEPTH   ?= 1024
PARAM_DEPTH ?= 256
LANES       ?= 2
BEAT        ?= 16        # the DDR3 port's beat in bytes: 16 (128-bit) or 32 (256-bit, LANES=4 at N=8)
RTL_SIM_DIR := $(SIM_DIR)/verilator/core_n$(N)$(if $(filter 2,$(LANES)),,_l$(LANES))$(if $(filter 16,$(BEAT)),,_b$(BEAT))
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
		-GACC_DEPTH=$(ACC_DEPTH) -GPARAMETER_DEPTH=$(PARAM_DEPTH) -GWEIGHT_LANES=$(LANES) \
		-GDDR_BEAT_BITS=$$(( $(BEAT) * 8 )) \
		-CFLAGS "-std=c++17 -DTB_N=$(N) -DTB_BEAT_BYTES=$(BEAT) -DTB_WMEM_ROWS=$(WMEM_ROWS) \
		         -DTB_UB_DEPTH=$(UB_DEPTH) -DTB_ACC_DEPTH=$(ACC_DEPTH) \
		         -DTB_PARAM_DEPTH=$(PARAM_DEPTH)" \
		$(CORE_RTL) $(TEST_DIR)/verilator/tb-isa.cpp -o tb_isa > /dev/null
	@echo "rtl-sim: $(RTL_SIM) (N=$(N), LANES=$(LANES), BEAT=$(BEAT))"

# tb_isa with VCD tracing, for the cycle-by-cycle visualizer (software/viz)
VIZ_SIM_DIR := $(SIM_DIR)/verilator/trace_n$(N)
VIZ_SIM     := $(VIZ_SIM_DIR)/tb_isa

viz-sim: | $(SIM_DIR)
	@mkdir -p $(VIZ_SIM_DIR)
	@$(VERILATOR) --cc --exe --build -j $(JOBS) -Wall --trace --Mdir $(VIZ_SIM_DIR) verilator.vlt \
		--top-module tpu_top \
		-GARRAY_SIZE=$(N) -GWMEM_ROWS=$(WMEM_ROWS) -GUB_DEPTH=$(UB_DEPTH) \
		-GACC_DEPTH=$(ACC_DEPTH) -GPARAMETER_DEPTH=$(PARAM_DEPTH) -GWEIGHT_LANES=$(LANES) \
		-GDDR_BEAT_BITS=$$(( $(BEAT) * 8 )) \
		-CFLAGS "-std=c++17 -DTB_TRACE -DTB_BEAT_BYTES=$(BEAT) -DTB_N=$(N) -DTB_WMEM_ROWS=$(WMEM_ROWS) \
		         -DTB_UB_DEPTH=$(UB_DEPTH) -DTB_ACC_DEPTH=$(ACC_DEPTH) \
		         -DTB_PARAM_DEPTH=$(PARAM_DEPTH)" \
		$(CORE_RTL) $(TEST_DIR)/verilator/tb-isa.cpp -o tb_isa > /dev/null
	@echo "viz-sim: $(VIZ_SIM) (N=$(N))"

# a workload through the traced model, and its cycle-by-cycle page
WORKLOAD ?= mlp
viz: viz-sim
	@python3 software/viz/visualize.py $(WORKLOAD) --n $(N) --visualize-internals $(VIZ_ARGS)

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
	@python3 $(ST_DIR)/gen_selftest.py $(ST_HEX) --n $(N) --lanes $(LANES)

selftest-sim: selftest-rom | $(SIM_DIR)
	@mkdir -p $(dir $(ST_SIM))
	@$(VERILATOR) --cc --exe --build -j $(JOBS) -Wall --Mdir $(dir $(ST_SIM)) verilator.vlt \
		--top-module tpu_selftest -GARRAY_SIZE=$(N) -GWEIGHT_LANES=$(LANES) -GROM_FILE='"$(abspath $(ST_HEX))"' \
		-CFLAGS -std=c++17 $(CORE_RTL) $(HPS_DIR)/replay.sv $(HPS_DIR)/tpu-selftest.sv \
		$(TEST_DIR)/verilator/tb-isa-selftest.cpp -o tb_isa_selftest > /dev/null
	@$(ST_SIM) $(ST_SLOTS)

# the DE1-SoC DDR3 bandwidth probe against a model of the FPGA-to-SDRAM port
DDR_PROBE_SIM := $(SIM_DIR)/verilator/ddr_probe/tb_ddr_probe

ddr-probe-sim: | $(SIM_DIR)
	@mkdir -p $(dir $(DDR_PROBE_SIM))
	@$(VERILATOR) --cc --exe --build -j $(JOBS) -Wall --Mdir $(dir $(DDR_PROBE_SIM)) verilator.vlt \
		--top-module ddr_probe -CFLAGS -std=c++17 $(HPS_DIR)/ddr-probe.sv \
		$(TEST_DIR)/verilator/tb-ddr-probe.cpp -o tb_ddr_probe > /dev/null
	@$(DDR_PROBE_SIM)

.PHONY: model-test rtl-sim viz-sim viz rtl-test sim-test selftest-rom selftest-sim ddr-probe-sim
