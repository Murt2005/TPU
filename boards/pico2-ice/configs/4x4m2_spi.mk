# 4x4 array (16 PEs, two per SB_MAC16 via pe_pair), M_TILE=2, SPI link,
# 24 MHz core. Needs the TPU_LINK_SPI firmware. The fastest single-image
# build: 4,397 LCs (83%), 8/8 DSP, 28.63 MHz fMax; MNIST 63.8 ms/image.
ARRAY_ROWS     := 4
NUM_COLS       := 4
M_TILE         := 2
PSUM_WIDTH     := 16
USE_SPI        := 1
USE_MAC16_PAIR := 1
CLK_FREQ       := 24000000
BAUD_RATE      := 1000000
