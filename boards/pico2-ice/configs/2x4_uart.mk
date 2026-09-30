# 2x4 array (8 PEs, one per SB_MAC16), UART link at 1 Mbaud, 12 MHz core.
# Measured: 3,538 LCs (67%), 8/8 DSP, 31.61 MHz fMax; MNIST ~240 ms/image.
ARRAY_ROWS     := 2
NUM_COLS       := 4
M_TILE         := 2
PSUM_WIDTH     := 16
USE_SPI        := 0
USE_MAC16_PAIR := 0
CLK_FREQ       := 12000000
BAUD_RATE      := 1000000
