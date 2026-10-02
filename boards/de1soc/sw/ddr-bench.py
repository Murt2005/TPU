"""How fast the core streams weights from DDR3, measured on the DE1-SoC with the
on-chip counters (the console link's milliseconds never enter): a MATMUL takes
max(m, N) cycles a tile plus every cycle the array waits for weights
(PERF_MM_WSTALL), so stalls against tiles give the streaming efficiency exactly.

    python boards/de1soc/sw/ddr-bench.py serial:/dev/cu.usbserial-<id>0

boot the board with ddr-boot.py first. timing doesn't depend on the weights'
values, so the big layers read whatever DDR3 holds; WT and MM are held until
the whole program is queued, so the link's pace doesn't either.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "..", "host"))
from tpu import isa  # noqa: E402
from tpu.isa_device import BoardConsole, IsaDevice, open_link  # noqa: E402

CLOCK_HZ = 50e6


def gated(n, program):
    """WT and MM wait on a WR_UB whose data is pushed after the program"""
    return [isa.wr_ub(0, 1), isa.wait(isa.WT, isa.LD), isa.wait(isa.MM, isa.LD)] + program, [0] * (n // 4)


def matmul_run(dev, n, m, k_tiles, n_blocks, wsrc, base_tile):
    prog, data = gated(n, [isa.set_wbase(base_tile), isa.matmul(m, k_tiles, n_blocks, 0, 0, wsrc=wsrc),
                           isa.signal(1)])
    dev.reset()
    dev.run(prog, data, timeout=120)
    p = dev.perf()
    tiles = k_tiles * n_blocks
    assert p["mm_beats"] == tiles * m, p
    compute = tiles * max(m, n)
    return dict(tiles=tiles, stall=p["mm_wstall"], compute=compute,
                efficiency=compute / (compute + p["mm_wstall"]),
                weight_mb_s=tiles * n * n / ((compute + p["mm_wstall"]) / CLOCK_HZ) / 1e6)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("link", help="serial:/dev/cu.usbserial-<id>0 (or a tb_isa binary)")
    ap.add_argument("--load", action="store_true", help="also with the ARM streaming 64 MB (ddr_probe load)")
    args = ap.parse_args()

    if args.load:       # in the console's shell, before isa_mmio takes the line over
        if not args.link.startswith("serial:"):
            sys.exit("--load is for the board")
        console = BoardConsole(args.link.split(":")[1])
        console.run("/mnt/boot/ddr_probe load 40 &", 1)
        console.close(quit_byte=None)
    link = open_link(args.link)
    dev = IsaDevice(link)
    n = link.n
    base = link.ddr_window[0] // (n * n)
    print(f"N={n}, {CLOCK_HZ / 1e6:.0f} MHz; a tile is {n * n} bytes of weights"
          + ("; the ARM streaming through 64 MB of its own memory" if args.load else ""))
    print(f"{'layer':<34} {'m':>3} {'src':>5} {'tiles':>7} {'stall cyc':>9} {'efficiency':>10} {'weights MB/s':>12}")
    shapes = [("one tile", 1, 1), ("MNIST layer 1 (144 x 64)", 18, 8),
              ("WMEM's capacity (1024 tiles)", 32, 32),
              ("Qwen q/k/v fused (896 x 1152)", 112, 144), ("Qwen down (4864 x 896)", 608, 112)]
    for name, k_tiles, n_blocks in shapes:
        for m in (1, n):
            if n_blocks * m > link.acc_depth or k_tiles * m > link.ub_depth:
                continue
            for wsrc in (0, 1):
                if not wsrc and k_tiles * n_blocks * n > link.wmem_rows:
                    continue
                r = matmul_run(dev, n, m, k_tiles, n_blocks, wsrc, base if wsrc else 0)
                print(f"{name:<34} {m:>3} {'DDR3' if wsrc else 'WMEM':>5} {r['tiles']:>7} {r['stall']:>9} "
                      f"{100 * r['efficiency']:>9.2f}% {r['weight_mb_s']:>12.1f}")
    link.close()
    if args.load:
        console = BoardConsole(args.link.split(":")[1])
        console.run("kill %1", 1)
        console.close(quit_byte=None)


if __name__ == "__main__":
    main()
