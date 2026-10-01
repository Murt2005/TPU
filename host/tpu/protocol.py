"""wire-protocol constants, mirroring rtl/core/tpu_pkg.sv (make check-protocol)"""

CMD_LOAD_WEIGHTS = 0x01
CMD_LOAD_BIAS = 0x02
CMD_LOAD_ACT = 0x03
CMD_RUN = 0x04
CMD_RESET = 0x05
CMD_RUN_TILE = 0x06
CMD_STREAM_RUN = 0x07
CMD_NOP = 0xFF          # SPI read-poll filler, ignored in S_IDLE

FLAG_TILE_FIRST = 0x01
FLAG_TILE_LAST = 0x02
FLAG_ACT_BYPASS = 0x04

# PSUM_WIDTH -> wire dtype of one bias/result element
PSUM_DTYPE = {8: "<i1", 16: "<i2", 32: "<i4", 64: "<i8"}

FW_MATMUL = 0xF0
FW_PROBE = 0xF1
FW_PROBE_MAGIC = b"T\x01"  # firmware's FW_MAGIC + FW_VERSION

# the stock SDK bridge drops bytes past its 32-deep UART FIFO, so UART writes
# are paced in chunks; redundant with this repo's firmware, kept for stock ones
BRIDGE_FIFO_BYTES = 32
BRIDGE_CHUNK_BYTES = 28

STATUS_OK = 0xAA
STATUS_ERR = 0xFF

# SPI write clock, for wire-time accounting only (reads are slower, so a lower bound)
SPI_WIRE_HZ = 4_000_000

# must match the bitstream's BAUD_RATE; the RP2350 follows whatever the host opens at
DEFAULT_BAUD = 1_000_000

FPGA_CLK_FREQ = 12_000_000


def pack_flags(first, last, act_bypass=False):
    return ((FLAG_TILE_FIRST if first else 0)
            | (FLAG_TILE_LAST if last else 0)
            | (FLAG_ACT_BYPASS if act_bypass else 0))
