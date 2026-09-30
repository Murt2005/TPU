"""Host driver for the TPU: `from tpu import TPU`.

Modules: protocol (wire constants), links (transports), driver (the TPU
class), golden (reference numerics), cli (`python3 -m tpu`).
"""
from . import golden
from .driver import TPU
from .links import LINKS, MmioLink, SimLink, TPUError
from .protocol import *  # noqa: F401,F403 -- CMD_*, FLAG_*, STATUS_*, DEFAULT_BAUD, ...
