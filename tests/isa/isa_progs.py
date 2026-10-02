"""random instruction-stream programs over a small address space, for the
phase 3 concurrency tests. WAITs come from tpu.isa_waits, never by hand"""
import numpy as np

from tpu import isa

WTILES, UB, ACC, PAR = 16, 64, 32, 8
DDR_REGION = 4096          # bytes of DDR3 the DDR3 ops share, so they collide often


def init_program(n, rng):
    """defines every memory the random programs touch, so RTL and model agree"""
    wm = rng.integers(-128, 128, (WTILES * n, n))
    ub = rng.integers(-128, 128, (UB, n))
    bias = rng.integers(-5000, 5000, (PAR, n))
    quant = [isa.quant_word(int(rng.integers(1 << 23, 1 << 24)), int(rng.integers(12, 24)))
             for _ in range(PAR * n)]
    prog = [isa.wr_wmem(0, WTILES * n), isa.wr_ub(0, UB), isa.wr_bias(0, PAR), isa.wr_quant(0, PAR),
            isa.wait(isa.WT, isa.LD), isa.wait(isa.MM, isa.LD), isa.set_wbase(0),
            isa.matmul(ACC, 1, 1, 0, 0), isa.signal(1)]
    data = (isa.pack_int8(wm) + isa.pack_int8(ub) + isa.pack_int32(bias.ravel())
            + isa.pack_int32(quant))
    return prog, data


def random_program(n, rng, length=30, max_data=700, ddr_base=None):
    """(program without WAITs, data). every op is legal and in range. with
    ddr_base, the program also uses DDR3_REGION bytes of DDR3 there: RD_DDR_UB,
    ACTIVATE dst=DDR, and MATMULs from DDR3 (the host fills the region first)"""
    prog, data = [], []
    kinds = ["wmem", "ub", "bias", "quant", "matmul", "matmul", "matmul", "act_host", "act_ub", "rd_ub"]
    if ddr_base is not None:
        kinds += ["rd_ddr", "act_ddr", "matmul_ddr", "matmul_ddr"]
    for _ in range(length):
        kind = rng.choice(kinds)
        if kind == "wmem":
            t = int(rng.integers(0, WTILES))
            cnt = int(rng.integers(1, min(3, WTILES - t) + 1))
            if len(data) + cnt * n * n // 4 > max_data:
                continue
            prog.append(isa.wr_wmem(t * n, cnt * n))
            data += isa.pack_int8(rng.integers(-128, 128, (cnt * n, n)))
        elif kind == "ub":
            a = int(rng.integers(0, UB))
            cnt = int(rng.integers(1, min(16, UB - a) + 1))
            if len(data) + cnt * n // 4 > max_data:
                continue
            prog.append(isa.wr_ub(a, cnt))
            data += isa.pack_int8(rng.integers(-128, 128, (cnt, n)))
        elif kind in ("bias", "quant"):
            p = int(rng.integers(0, PAR))
            cnt = int(rng.integers(1, PAR - p + 1))
            if len(data) + cnt * n > max_data:
                continue
            if kind == "bias":
                prog.append(isa.wr_bias(p, cnt))
                data += isa.pack_int32(rng.integers(-5000, 5000, cnt * n))
            else:
                prog.append(isa.wr_quant(p, cnt))
                data += [isa.quant_word(int(rng.integers(1 << 23, 1 << 24)), int(rng.integers(12, 24)))
                         for _ in range(cnt * n)]
        elif kind == "matmul":
            m = int(rng.choice([1, 2, n - 1, n, n + 3, 2 * n + 1]))
            nb = int(rng.integers(1, 3))
            kt = int(rng.integers(1, 4))
            while nb * kt > WTILES or kt * m > UB or nb * m > ACC:
                m = max(1, m // 2)
                kt = max(1, kt - 1)
            prog += [isa.set_wbase(int(rng.integers(0, WTILES - nb * kt + 1))),
                     isa.matmul(m, kt, nb, int(rng.integers(0, ACC - nb * m + 1)),
                                int(rng.integers(0, UB - kt * m + 1)),
                                accumulate=bool(rng.integers(0, 2)))]
        elif kind in ("act_host", "act_ub"):
            m = int(rng.integers(1, 9))
            nb = int(rng.integers(1, 3))
            to_ub = kind == "act_ub"
            prog.append(isa.activate(nb, m, int(rng.integers(0, ACC - nb * m + 1)),
                                     func=int(rng.integers(0, 2)),
                                     rq=to_ub or bool(rng.integers(0, 2)),
                                     dst=isa.DST_UB if to_ub else isa.DST_HOST,
                                     bias=bool(rng.integers(0, 2)),
                                     ub_addr=int(rng.integers(0, UB - nb * m + 1)) if to_ub else 0,
                                     param_idx=int(rng.integers(0, PAR - nb + 1))))
        elif kind == "rd_ddr":
            cnt = int(rng.integers(1, 17))
            a = int(rng.integers(0, UB - cnt + 1))
            entry = int(rng.integers(0, DDR_REGION // n - cnt + 1))
            prog.append(isa.rd_ddr_ub(a, cnt, ddr_base + entry * n))
        elif kind == "act_ddr":
            m = int(rng.integers(1, 5))
            nb = int(rng.integers(1, 3))
            rq = bool(rng.integers(0, 2))
            size = nb * m * (n if rq else 4 * n)
            word = int(rng.integers(0, (DDR_REGION - size) // 4 + 1))
            prog += [isa.set_obase(ddr_base + 4 * word),
                     isa.activate(nb, m, int(rng.integers(0, ACC - nb * m + 1)), func=int(rng.integers(0, 2)),
                                  rq=rq, dst=isa.DST_DDR, bias=bool(rng.integers(0, 2)),
                                  param_idx=int(rng.integers(0, PAR - nb + 1)))]
        elif kind == "matmul_ddr":
            tiles_in_region = DDR_REGION // (n * n)
            m = int(rng.choice([1, 2, n, n + 3]))
            nb, kt = int(rng.integers(1, 3)), int(rng.integers(1, 4))
            prog += [isa.set_wbase(ddr_base // (n * n) + int(rng.integers(0, tiles_in_region - nb * kt + 1))),
                     isa.matmul(m, kt, nb, int(rng.integers(0, ACC - nb * m + 1)),
                                int(rng.integers(0, UB - kt * m + 1)), accumulate=bool(rng.integers(0, 2)), wsrc=1)]
        else:
            a = int(rng.integers(0, UB))
            prog.append(isa.rd_ub(a, int(rng.integers(1, min(8, UB - a) + 1))))
    return prog, data
