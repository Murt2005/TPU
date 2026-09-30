#!/usr/bin/env python3
"""Compatibility entry point: `python3 tpu_host.py ...` runs the host CLI,
and `import tpu_host` still exposes the driver.

The driver itself is the `tpu` package in host/ -- install it with
`pip install -e host` (requirements.txt does this) and use `python3 -m tpu`
or `from tpu import TPU`. This file only exists so older commands and
scripts keep working, including on machines where the package isn't
installed.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "host"))

from tpu import *  # noqa: E402,F401,F403
from tpu.cli import main  # noqa: E402

if __name__ == "__main__":
    main()
