## ============================================================================
##  mk/hw.mk — real-hardware regression against a flashed pico2-ice
## ============================================================================

# ----------------------------------------------------------------------------
# Real-hardware regression suite (pico2-ice) -- see tests/hw/hw_regression.py
# ----------------------------------------------------------------------------
# ARRAY_ROWS/NUM_COLS/M_TILE must match the flashed bitstream's shape
# (boards/pico2-ice/fpga/Makefile's knobs of the same names); defaults match both. LINK must
# match the flashed PHY: uart, or spi (USE_SPI=1 gateware + TPU_LINK_SPI
# firmware).
ARRAY_ROWS ?= 2
NUM_COLS   ?= 2
M_TILE     ?= $(ARRAY_ROWS)
LINK       ?= uart

hw-test:
	@if [ -z "$(PORT)" ]; then \
		echo "Usage: make hw-test PORT=/dev/cu.usbmodemXXXX [ARRAY_ROWS=2 NUM_COLS=2 M_TILE=2 LINK=uart]"; exit 1; \
	fi
	python3 tests/hw/hw_regression.py --port $(PORT) \
		--rows $(ARRAY_ROWS) --cols $(NUM_COLS) --m-tile $(M_TILE) --link $(LINK)

.PHONY: hw-test
