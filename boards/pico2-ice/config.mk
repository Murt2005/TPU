# loads configs/$(CONFIG).mk for both the fpga build and make hw-test;
# the includer sets PICO_CONFIG_DIR, and command-line knobs still win

ifneq ($(CONFIG),)
PICO_CONFIG_FILE := $(PICO_CONFIG_DIR)/$(CONFIG).mk
ifeq ($(wildcard $(PICO_CONFIG_FILE)),)
$(error No config '$(CONFIG)'. Available: $(sort $(notdir $(basename $(wildcard $(PICO_CONFIG_DIR)/*.mk)))))
endif
include $(PICO_CONFIG_FILE)
endif

# recursive (=) so they see defaults the includer sets after this file
PICO_LINK       = $(if $(filter-out 0,$(USE_SPI)),spi,uart)
PICO_FIRMWARE   = $(if $(filter-out 0,$(USE_SPI)),build-spi (cmake -DTPU_LINK_SPI=ON),build (UART bridge))
PICO_HOST_FLAGS = --rows $(ARRAY_ROWS) --cols $(NUM_COLS) --m-tile $(M_TILE) --psum-width $(PSUM_WIDTH) --link $(PICO_LINK)
