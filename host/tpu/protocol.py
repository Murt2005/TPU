"""Wire-protocol constants for the host<->TPU link.

The opcodes, flag bits and status bytes mirror rtl/core/tpu_pkg.sv, the
canonical (RTL) side of the contract; `make check-protocol` verifies every
copy agrees. The frame formats are documented in rtl/core/tpu_sequencer.sv's
header and docs/protocol.md.
"""

# Wire-protocol opcodes / status bytes. These mirror rtl/core/tpu_pkg.sv, which is
# the canonical (RTL) side of the host<->FPGA contract -- keep the two in sync.
CMD_LOAD_WEIGHTS = 0x01
CMD_LOAD_BIAS = 0x02
CMD_LOAD_ACT = 0x03
CMD_RUN = 0x04
CMD_RESET = 0x05
CMD_RUN_TILE = 0x06
CMD_STREAM_RUN = 0x07
CMD_NOP = 0xFF          # ignored in S_IDLE, no response -- the SPI read-poll filler

# RUN-family flags byte (CMD_RUN LEN=1, CMD_RUN_TILE payload[0],
# CMD_STREAM_RUN frame header byte 0). Mirrors tpu_pkg's FLAG_* localparams.
FLAG_TILE_FIRST = 0x01   # overwrite the accumulator's running sum
FLAG_TILE_LAST = 0x02    # forward the final sum through bias/activation
FLAG_ACT_BYPASS = 0x04   # skip the ReLU clamp on this pass

# PSUM_WIDTH -> the numpy dtype one bias/result element takes on the wire.
# Must match the bitstream's PSUM_WIDTH (rtl/core/tpu_sequencer.sv's parameter).
PSUM_DTYPE = {8: "<i1", 16: "<i2", 32: "<i4", 64: "<i8"}

FW_MATMUL = 0xF0
FW_PROBE = 0xF1
FW_PROBE_MAGIC = b"T\x01"  # boards/pico2-ice/firmware/tpu_tile.c's FW_MAGIC + FW_VERSION

# One STREAM_RUN tile = rows*cols weight + m_tile*rows act payload bytes; the
# 1-byte LEN caps a frame at 255 payload bytes, minus 2 header bytes (flags,
# K_TILES). Both are shape-dependent, computed per TPU instance in __init__
# (self.stream_tile_bytes / self.max_stream_tiles: 8 and 31 at 2x2/M_TILE=2,
# 12 and 21 at the 2x4/M_TILE=2 hardware shape).

# The pico2-ice firmware's stock USB->UART bridge (pico-ice-sdk
# ice_usb_cdc_to_uart0) silently DROPS bytes once the RP2350's 32-deep UART
# TX FIFO is full, and USB delivers a burst far faster than the UART drains
# it -- so any frame longer than the FIFO loses its tail. Pace writes bigger
# than one FIFO's worth down to wire speed (chunks + drain-time sleeps);
# this costs nothing measurable since the UART is the throughput floor
# anyway, and stays correct (just redundant) once the firmware-side fix in
# boards/pico2-ice/firmware/main.c (blocking bridge write) is flashed.
BRIDGE_FIFO_BYTES = 32
BRIDGE_CHUNK_BYTES = 28  # a little margin under the FIFO depth

STATUS_OK = 0xAA
STATUS_ERR = 0xFF

# link="spi" (TPU_LINK_SPI firmware + USE_SPI=1 gateware): the CDC port is
# bridged to the RP2350<->iCE40 SPI bus instead of uart0. Two host-side
# differences, both handled by TPU(link=...):
#  - no write pacing: the SPI bridge reads the CDC FIFO under TinyUSB flow
#    control (no 32-byte UART FIFO to overrun), so the BRIDGE_* sleeps
#    below would just emulate UART-era latency for nothing;
#  - wire-time accounting: SPI moves 8 bits/byte at the bridge's write
#    clock (boards/pico2-ice/firmware/main.c TPU_SPI_WRITE_HZ; reads are slower and add
#    poll filler, so uart_wire_seconds() is a lower bound there).
SPI_WIRE_HZ = 4_000_000

# Must match boards/pico2-ice/fpga/Makefile's BAUD_RATE (the divider is baked into the
# bitstream at synthesis time). The RP2350 bridge needs no matching change:
# pico-ice-sdk's tud_cdc_line_coding_cb sets uart0's baud to whatever rate
# the host opens the CDC port with. 1M divides the 12 MHz FPGA clock exactly
# (TICKS_PER_BIT = 12, zero baud error).
DEFAULT_BAUD = 1_000_000

# Must match boards/pico2-ice/fpga/Makefile's CLK_FREQ (default 12 MHz) and boards/pico2-ice/firmware/main.c's
# ice_fpga_init() request -- the clock the RP2350 actually exports to the
# FPGA on real pico2-ice hardware, not iverilog sim's 50 MHz DE1-SoC default.
FPGA_CLK_FREQ = 12_000_000


def pack_flags(first, last, act_bypass=False):
    """Pack the RUN-family flags byte (see FLAG_* above)."""
    return ((FLAG_TILE_FIRST if first else 0)
            | (FLAG_TILE_LAST if last else 0)
            | (FLAG_ACT_BYPASS if act_bypass else 0))
