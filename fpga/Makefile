## ============================================================================
##  fpga/ — board-target dispatcher
##
##  Each supported board has its own subdirectory with a self-contained build:
##    fpga/ice40/    pico2-ice (iCE40UP5K) — yosys -> nextpnr-ice40 -> icepack
##                   -> dfu-util. Bring-up complete, hardware-validated.
##    fpga/de1soc/   DE1-SoC (Cyclone V)   — Quartus Prime, driven from the ARM
##                   HPS over the lightweight FPGA bridge. (Planned.)
##
##  Usage:
##    make -C fpga ice40                 # build the ice40 bitstream (default target)
##    make -C fpga ice40 TARGET=prog     # run a specific sub-target (e.g. prog, util)
##    make -C fpga de1soc TARGET=...      # once fpga/de1soc/ exists
##
##  Or just cd into a board directory and use its Makefile directly.
## ============================================================================

BOARDS := ice40 de1soc

.PHONY: all $(BOARDS)

all:
	@echo "Specify a board target. Available boards: $(BOARDS)"
	@echo "  make -C fpga ice40 [TARGET=prog|util|time|clean|...]"
	@echo "  (or cd into fpga/<board> and run its Makefile directly)"

$(BOARDS):
	$(MAKE) -C $@ $(TARGET)
