/*
 * tpu_tile -- SPI host link + on-RP2350 matmul tiling offload
 * (TPU_LINK_SPI=1 builds only; see tpu_tile.c's header comment).
 */
#pragma once

#if TPU_LINK_SPI

// FPGA core clock for SPI builds: 24 MHz (vs. the UART build's 12 MHz --
// the UART baud divider is synthesis-baked against CLK_FREQ, but the SPI
// slave has no such coupling, and this design's measured fMax is ~32 MHz).
// Both SPI clocks scale with it: write <= CLK/6, read <= CLK/8 (tpu_tile.c).
// The gateware must be built with the matching CLK_FREQ=24000000.
#define TPU_TILE_FPGA_CLK_MHZ 24

// Claim the spi0 pins after ice_fpga_start(), park the shared-bus flash in
// deep power-down, and drain the FPGA's error response to that frame.
void tpu_tile_init(void);

// One main-loop service step: route host CDC bytes (forwarding FPGA-protocol
// frames over SPI, capturing firmware commands 0xF0/0xF1 locally), execute a
// completed FW_MATMUL, or poll the FPGA for a pending response to forward.
void tpu_tile_service(void);

#endif
