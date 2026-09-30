# 2x4 array, SPI link, 24 MHz core. Needs the TPU_LINK_SPI firmware.
# Measured: 3,538 LCs (67%), 8/8 DSP; MNIST 64.1 ms/image with the
# FW_MATMUL offload.
ARRAY_ROWS     := 2
NUM_COLS       := 4
M_TILE         := 2
PSUM_WIDTH     := 16
USE_SPI        := 1
USE_MAC16_PAIR := 0
CLK_FREQ       := 24000000
BAUD_RATE      := 1000000
