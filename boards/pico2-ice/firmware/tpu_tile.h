// SPI host link + FW_MATMUL offload, TPU_LINK_SPI builds only
#pragma once

#if TPU_LINK_SPI

// SPI builds run the FPGA at 24 MHz (no baud divider to match); the gateware
// needs CLK_FREQ=24000000, and both SPI clocks scale with it
#define TPU_TILE_FPGA_CLK_MHZ 24

void tpu_tile_init(void);
void tpu_tile_service(void);

#endif
