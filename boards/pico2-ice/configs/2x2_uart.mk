# 2x2 array, UART link at 1 Mbaud, 12 MHz core. The default build and the
# bisect fallback. Measured: 2,138 LCs (40%), 4/8 DSP, 30.66 MHz fMax;
# make hw-test 14/14; MNIST ~316 ms/image.
ARRAY_ROWS     := 2
NUM_COLS       := 2
M_TILE         := 2
PSUM_WIDTH     := 16
USE_SPI        := 0
USE_MAC16_PAIR := 0
CLK_FREQ       := 12000000
BAUD_RATE      := 1000000
