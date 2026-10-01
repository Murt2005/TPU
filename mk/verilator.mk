# each top is linted with its own board's file set, as its toolchain sees it
check-protocol:
	@python3 $(TEST_DIR)/check_protocol.py

# a drifted opcode is as silent as a width bug, so lint includes the protocol check
lint: $(SB_MAC16_SIM) check-protocol
	$(VERILATOR) --lint-only -Wall --timing -sv verilator.vlt \
		$(PICO_RTL) --top-module tpu_top
	$(VERILATOR) --lint-only -Wall --timing -sv verilator.vlt \
		-GUSE_SPI=1 $(PICO_RTL) --top-module tpu_top
	$(VERILATOR) --lint-only -Wall --timing -sv verilator.vlt \
		-GUSE_SPI=1 -GUSE_MAC16_PAIR=1 -GARRAY_ROWS=4 -GNUM_COLS=4 -GM_TILE=4 \
		$(PICO_RTL) --top-module tpu_top
	$(VERILATOR) --lint-only -Wall --timing -sv verilator.vlt \
		$(HPS_RTL) --top-module tpu_top_hps
	$(VERILATOR) --lint-only -Wall --timing -sv verilator.vlt \
		$(ISA_RTL) --top-module tpu_isa_top
	@echo "lint: clean (UART + SPI + 4x4 MAC16-pair + HPS + instruction-stream configs)"

# ROWS_COLS_MTILE_PHY[32]: spipair = SPI + pe_pair, 32 = PSUM_WIDTH=32,
# direct = bytes injected into tpu_core, skipping the PHY (~50x fewer cycles).
# 8_8_4_uart32 uses M_TILE=4: 8x8 at 4 bytes/element would exceed the 255-byte LEN
VERILATE_SHAPES := 2_2_2_uart 2_4_2_uart 4_2_3_uart 2_4_2_spi 4_4_2_spipair 4_4_4_spipair \
                   8_8_8_uart 2_2_2_uart32 4_4_2_spi32 8_8_4_uart32 \
                   2_2_2_direct 8_8_4_direct32

# defaults are the transformer's shape, independent of the test matrix above
SIM_ROWS  ?= 8
SIM_COLS  ?= 8
SIM_MTILE ?= 4
SIM_PSUM  ?= 32
SIM_FD    ?= 8
SIM_BRIDGE_DIR := $(SIM_DIR)/verilator/bridge
SIM_BRIDGE     := $(SIM_BRIDGE_DIR)/tb_tpu_top

sim-bridge: $(SB_MAC16_SIM) | $(SIM_DIR)
	@mkdir -p $(SIM_BRIDGE_DIR)
	@$(VERILATOR) --cc --exe --build -j 0 -Wall \
		--Mdir $(SIM_BRIDGE_DIR) verilator.vlt \
		--top-module tpu_core \
		-GFIFO_DEPTH=$(SIM_FD) -GARRAY_ROWS=$(SIM_ROWS) -GNUM_COLS=$(SIM_COLS) \
		-GM_TILE=$(SIM_MTILE) -GPSUM_WIDTH=$(SIM_PSUM) \
		-CFLAGS "-std=c++17 -DTB_ROWS=$(SIM_ROWS) -DTB_COLS=$(SIM_COLS) \
		         -DTB_MTILE=$(SIM_MTILE) -DTB_PSUM_WIDTH=$(SIM_PSUM) -DTB_DIRECT" \
		$(PICO_RTL) $(TEST_DIR)/verilator/tb_tpu_top.cpp \
		-o tb_tpu_top > /dev/null
	@echo "sim-bridge: $(SIM_BRIDGE) ($(SIM_ROWS)x$(SIM_COLS) M_TILE=$(SIM_MTILE) PSUM=$(SIM_PSUM))"
	@echo "  use: python3 tpu_host.py --link sim --port $(SIM_BRIDGE) \
--rows $(SIM_ROWS) --cols $(SIM_COLS) --m-tile $(SIM_MTILE) --psum-width $(SIM_PSUM) --selftest"

verilate-test: $(SB_MAC16_SIM) | $(SIM_DIR)
	@set -e; for shape in $(VERILATE_SHAPES); do \
		rows=$${shape%%_*}; rest=$${shape#*_}; \
		cols=$${rest%%_*}; rest=$${rest#*_}; \
		mt=$${rest%%_*}; phy=$${rest#*_}; \
		psum=16; case "$$phy" in *32) psum=32; phy=$${phy%32};; esac; \
		objdir=$(SIM_DIR)/verilator/$${rows}x$${cols}m$${mt}_$${phy}p$${psum}; \
		mkdir -p $$objdir; \
		phyflags=""; phycflags=""; \
		topmod=tpu_top; clkflags="-GCLK_FREQ=12000000 -GBAUD_RATE=1000000"; \
		if [ "$$phy" = "spi" ]; then \
			phyflags="-GUSE_SPI=1"; phycflags="-DTB_SPI"; \
		elif [ "$$phy" = "spipair" ]; then \
			phyflags="-GUSE_SPI=1 -GUSE_MAC16_PAIR=1"; phycflags="-DTB_SPI"; \
		elif [ "$$phy" = "direct" ]; then \
			topmod=tpu_core; clkflags=""; phycflags="-DTB_DIRECT"; \
		fi; \
		fd=4; m=$$rows; [ $$mt -gt $$m ] && m=$$mt; \
		while [ $$fd -lt $$m ]; do fd=$$((fd*2)); done; \
		echo "=== verilate $${rows}x$${cols} M_TILE=$${mt} FIFO_DEPTH=$${fd} PSUM=$${psum} ($${phy}) ==="; \
		$(VERILATOR) --cc --exe --build -j 0 -Wall \
			--Mdir $$objdir verilator.vlt \
			--top-module $$topmod \
			$$clkflags -GFIFO_DEPTH=$$fd \
			-GARRAY_ROWS=$$rows -GNUM_COLS=$$cols -GM_TILE=$$mt -GPSUM_WIDTH=$$psum $$phyflags \
			-CFLAGS "-std=c++17 -DTB_ROWS=$$rows -DTB_COLS=$$cols -DTB_MTILE=$$mt -DTB_PSUM_WIDTH=$$psum $$phycflags" \
			$(PICO_RTL) $(TEST_DIR)/verilator/tb_tpu_top.cpp \
			-o tb_tpu_top > /dev/null; \
		$$objdir/tb_tpu_top; \
	done
	@echo "verilate-test: all shapes passed"

.PHONY: check-protocol lint verilate-test sim-bridge
