## ============================================================================
##  boards/pico2-ice/config.mk — named build configurations
##
##  Included by boards/pico2-ice/fpga/Makefile (the bitstream) and the root
##  mk/hw.mk (make hw-test), so both read the same settings:
##
##    make CONFIG=4x4_spi              in boards/pico2-ice/fpga/
##    make hw-test CONFIG=4x4_spi PORT=/dev/cu.usbmodemXXXX
##    make host-flags CONFIG=4x4_spi   the matching tpu_host.py flags
##
##  Each configs/<name>.mk sets every knob. A knob given on the command line
##  still wins over the config. The includer must set PICO_CONFIG_DIR first.
## ============================================================================

ifneq ($(CONFIG),)
PICO_CONFIG_FILE := $(PICO_CONFIG_DIR)/$(CONFIG).mk
ifeq ($(wildcard $(PICO_CONFIG_FILE)),)
$(error No config '$(CONFIG)'. Available: $(sort $(notdir $(basename $(wildcard $(PICO_CONFIG_DIR)/*.mk)))))
endif
include $(PICO_CONFIG_FILE)
endif

# Derived from the knobs. Recursive (=) so they see defaults the includer
# sets after this file.
PICO_LINK       = $(if $(filter-out 0,$(USE_SPI)),spi,uart)
PICO_FIRMWARE   = $(if $(filter-out 0,$(USE_SPI)),build-spi (cmake -DTPU_LINK_SPI=ON),build (UART bridge))
PICO_HOST_FLAGS = --rows $(ARRAY_ROWS) --cols $(NUM_COLS) --m-tile $(M_TILE) --psum-width $(PSUM_WIDTH) --link $(PICO_LINK)
