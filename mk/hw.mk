## ============================================================================
##  mk/hw.mk — real-hardware regression against a flashed pico2-ice
## ============================================================================

# The host flags must match the flashed bitstream. Easiest: name the same
# config the bitstream was built with (boards/pico2-ice/configs/):
#
#   make hw-test CONFIG=4x4_spi PORT=/dev/cu.usbmodemXXXX
#   make host-flags CONFIG=4x4_spi        # the flags for tpu_host.py etc.
#
# Or give the knobs individually (ARRAY_ROWS/NUM_COLS/M_TILE/PSUM_WIDTH, and
# LINK=uart|spi); the defaults match the default bitstream.
PICO_CONFIG_DIR := boards/pico2-ice/configs
include boards/pico2-ice/config.mk

ARRAY_ROWS ?= 2
NUM_COLS   ?= 2
M_TILE     ?= $(ARRAY_ROWS)
PSUM_WIDTH ?= 16
USE_SPI    ?= 0
LINK       ?= $(PICO_LINK)

hw-test:
	@if [ -z "$(PORT)" ]; then \
		echo "Usage: make hw-test PORT=/dev/cu.usbmodemXXXX [CONFIG=<name> | ARRAY_ROWS=2 NUM_COLS=2 M_TILE=2 LINK=uart]"; exit 1; \
	fi
	python3 tests/hw/hw_regression.py --port $(PORT) \
		--rows $(ARRAY_ROWS) --cols $(NUM_COLS) --m-tile $(M_TILE) \
		--psum-width $(PSUM_WIDTH) --link $(LINK)

host-flags:
	@echo "--rows $(ARRAY_ROWS) --cols $(NUM_COLS) --m-tile $(M_TILE) --psum-width $(PSUM_WIDTH) --link $(LINK)"

.PHONY: hw-test host-flags
