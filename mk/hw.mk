# host flags must match the flashed bitstream: pass the CONFIG it was built with,
# or the knobs individually
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
