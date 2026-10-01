"""compile an int8 MLP into a load program and an infer program for the
instruction-stream core. layers chain on chip: every layer but the last
requantizes into the UB, where the next layer reads it"""
import numpy as np

from . import isa
from .isa_layout import bias_entries, out_rows, ub_entries, weight_rows


class CompiledMlp:
    def __init__(self, layers, m, n):
        """layers: dicts with w (K x N int8), b (N ints, accumulator units),
        relu (bool) and scale (requant M for a chained layer, None for the
        last, which returns int32 to the host). m: rows per inference"""
        self.n, self.m, self.layers = n, m, layers
        self.plan = []
        wmem_rows, wbias, wquant = [], [], []
        par = 0
        acc = 0
        ub = 0
        for li, layer in enumerate(layers):
            rows, kt, nb = weight_rows(layer["w"], n)
            last = li == len(layers) - 1
            if last != (layer.get("scale") is None):
                raise ValueError("every layer but the last needs a requant scale")
            if li > 0 and kt != self.plan[-1]["nb"]:
                raise ValueError(f"layer {li}: K blocks {kt} != previous N blocks "
                                 f"{self.plan[-1]['nb']} (pad the previous layer's N)")
            wmem_rows.append(rows)
            wbias.append(bias_entries(layer["b"], n))
            if last:
                wquant.append(np.zeros((nb, n), np.int64))
            else:
                m0, shift = isa.quant_params(layer["scale"])
                wquant.append(np.full((nb, n), isa.quant_word(m0, shift), np.int64))
            in_ub = ub
            out_ub = in_ub + kt * m
            self.plan.append(dict(kt=kt, nb=nb, par=par, acc=acc, ub_in=in_ub, ub_out=out_ub,
                                  relu=layer.get("relu", True), last=last, n_out=layer["w"].shape[1]))
            par += nb
            acc += nb * m
            ub = out_ub
        self.wmem = np.concatenate(wmem_rows)
        self.bias = np.concatenate(wbias)
        self.quant = np.concatenate(wquant)
        self.k_in = layers[0]["w"].shape[0]

    def load_program(self):
        prog = [isa.wr_wmem(0, len(self.wmem)), isa.wr_bias(0, len(self.bias)),
                isa.wr_quant(0, len(self.quant)),
                isa.wait(isa.WT, isa.LD), isa.wait(isa.ACT, isa.LD), isa.signal(1)]
        data = (isa.pack_int8(self.wmem) + isa.pack_int32(self.bias.ravel())
                + isa.pack_int32(self.quant.ravel()))
        return prog, data

    def infer_program(self, x):
        """x: m x K int8. returns (program, data)"""
        m = self.m
        first = self.plan[0]
        ub = ub_entries(np.asarray(x), self.n)
        prog = [isa.wr_ub(first["ub_in"], len(ub)), isa.set_wbase(0), isa.wait(isa.MM, isa.LD)]
        for p in self.plan:
            prog += [isa.matmul(m, p["kt"], p["nb"], p["acc"], p["ub_in"]),
                     isa.wait(isa.ACT, isa.MM),
                     isa.activate(p["nb"], m, p["acc"],
                                  func=isa.FUNC_RELU if p["relu"] else isa.FUNC_IDENTITY,
                                  rq=not p["last"], dst=isa.DST_HOST if p["last"] else isa.DST_UB,
                                  bias=True, ub_addr=0 if p["last"] else p["ub_out"],
                                  param_idx=p["par"])]
            if not p["last"]:
                prog.append(isa.wait(isa.MM, isa.ACT))
        prog.append(isa.signal(2))
        return prog, isa.pack_int8(ub)

    def decode(self, out):
        last = self.plan[-1]
        return out_rows(out, self.m, last["nb"], self.n)[:, :last["n_out"]]


def compile_mlp(layers, m, n=8):
    return CompiledMlp(layers, m, n)
