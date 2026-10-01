#!/usr/bin/env python3
"""compatibility wrapper: runs the tpu CLI and re-exports the driver, with or
without the host/ package installed"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "host"))

from tpu import *  # noqa: E402,F401,F403
from tpu.cli import main  # noqa: E402

if __name__ == "__main__":
    main()
