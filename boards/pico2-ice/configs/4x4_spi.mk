# 4x4 array, M_TILE=4, SPI link, 24 MHz core. Needs the TPU_LINK_SPI
# firmware. The largest shape that fits: 4,935 LCs (93%), 8/8 DSP,
# 27.62 MHz fMax. Single-image MNIST is slower (80.3 ms) because 3 of 4
# streamed rows are padding; it pays off once images are batched.
ARRAY_ROWS     := 4
NUM_COLS       := 4
M_TILE         := 4
PSUM_WIDTH     := 16
USE_SPI        := 1
USE_MAC16_PAIR := 1
CLK_FREQ       := 24000000
BAUD_RATE      := 1000000
