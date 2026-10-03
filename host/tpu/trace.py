"""a tb_isa VCD (`make viz-sim`, IsaSimLink.trace) -> one record per clock cycle.

tb_isa samples once per cycle, just before the rising edge, so record t holds every
register as it stands in cycle t and every input the edge at the end of t takes:
a PE's activation_in, weight_in and partial_sum_in in record t are what it
multiply-accumulates at that edge. a VCD only writes what changed, so values carry
forward between timestamps.

the result is columnar-by-key: `keys` names each column, `rows` holds one list per
cycle. packed per-column buses become one key per lane (wd0..wd{N-1}), and PE
(r, c)'s ports are p{r}_{c}_<port>
"""

T = "tpu_top."
C = T + "u_core."


def _spec(n):
    """(key, VCD path, lanes, lane width, signed). lanes 0 is a plain scalar"""
    s = [
        # the host bus (Avalon-MM slave) and the FIFOs behind it
        ("wr", T + "avs_write", 0, 1, False), ("rd", T + "avs_read", 0, 1, False),
        ("addr", T + "avs_address", 0, 4, False), ("wreq", T + "avs_waitrequest", 0, 1, False),
        ("ipush", C + "instruction_push_in", 0, 1, False),
        ("dpush", C + "data_push_in", 0, 1, False),
        ("opop", C + "output_pop_in", 0, 1, False),
        # dispatch
        ("ipop", C + "instruction_pop", 0, 1, False), ("qpush", C + "queue_push", 0, 4, False),
        ("qpop", C + "queue_pop", 0, 4, False),
        ("disp", C + "dispatched", 4, 16, False), ("comp", C + "completed", 4, 16, False),
        ("fence", C + "fence_pending", 0, 1, False), ("done", C + "done_out", 0, 1, False),
        ("err", C + "error_out", 0, 1, False), ("idle", C + "idle_out", 0, 1, False),
        ("eidle", C + "engine_idle", 0, 4, False),
        # LD
        ("ld_busy", C + "u_load_engine.busy", 0, 1, False),
        ("ld_op", C + "u_load_engine.current_opcode", 0, 6, False),
        ("ld_left", C + "u_load_engine.items_left", 0, 17, False),
        ("ld_pop", C + "data_pop", 0, 1, False),
        ("wmem_we", C + "WMEM_write_enable", 0, 1, False),
        ("wmem_waddr", C + "WMEM_write_address", 0, 32, False),
        ("ub_we", C + "load_UB_write_enable", 0, 1, False),
        ("ub_waddr", C + "load_UB_write_address", 0, 32, False),
        ("ldr", C + "load_row_data", n, 8, True),
        ("par_we", C + "bias_write_enable", 0, 1, False),
        ("q_we", C + "quantization_write_enable", 0, 1, False),
        ("par_waddr", C + "parameter_write_address", 0, 32, False),
        ("ld_ddr", C + "u_load_engine.reading_DDR", 0, 1, False),
        # WT and the tile buffer
        ("wt_left", C + "u_weight_engine.tiles_left", 0, 32, False),
        ("wt_tile", C + "u_weight_engine.tile_index", 0, 32, False),
        ("wt_row", C + "u_weight_engine.row_in_tile", 0, 8, False),
        ("wt_issue", C + "u_weight_engine.issuing_read", 0, 1, False),
        ("wt_ddr", C + "u_weight_engine.from_DDR", 0, 1, False),
        ("wbase", C + "u_weight_engine.weight_base", 0, 32, False),
        ("fw", C + "fill_write_enable", 0, 1, False), ("fslot", C + "fill_slot", 0, 1, False),
        ("frow", C + "fill_row", 0, 8, False), ("fd", C + "fill_data", n, 8, True),
        ("wt_full", C + "u_weight_fifo.slot_full", 0, 2, False),
        ("wt_rd", C + "u_weight_fifo.drain_slot_index", 0, 1, False),
        ("wt_wr", C + "u_weight_fifo.fill_slot_index", 0, 1, False),
        # MM
        ("mm_state", C + "u_matmul_engine.state", 0, 2, False),
        ("mm_pos", C + "u_matmul_engine.window_position", 0, 9, False),
        ("mm_len", C + "u_matmul_engine.window_length", 0, 9, False),
        ("mm_k", C + "u_matmul_engine.k_tile_index", 0, 13, False),
        ("mm_kt", C + "u_matmul_engine.k_tiles", 0, 13, False),
        ("mm_m", C + "u_matmul_engine.activation_rows", 0, 9, False),
        ("mm_accb", C + "u_matmul_engine.ACC_base", 0, 16, False),
        ("mm_acts", C + "u_matmul_engine.window_has_activations", 0, 1, False),
        ("mm_wts", C + "u_matmul_engine.window_has_weights", 0, 1, False),
        ("mm_tleft", C + "u_matmul_engine.weight_tiles_left", 0, 32, False),
        ("mm_ubre", C + "matmul_UB_read_enable", 0, 1, False),
        ("mm_ubaddr", C + "matmul_UB_read_address", 0, 32, False),
        ("mm_freeze", C + "u_matmul_engine.window_frozen", 0, 1, False),
        ("mm_take", C + "tile_take", 0, 1, False),
        ("mm_sync", C + "performance_sync_stall", 0, 1, False),
        ("wv", C + "weight_valid", 0, 1, False),
        ("wrow", C + "weight_row_select", 0, 8, False),
        ("wd", C + "weight_data", n, 8, True),
        ("tagp", C + "tag_push", 0, 1, False), ("tagv", C + "row_tag", 0, 16, False),
        ("inflight", C + "u_matmul_engine.rows_in_flight", 0, 8, False),
        # accumulator
        ("cq", None, 0, 0, False),          # placeholder, expanded below per column
        ("row_pop", C + "u_accumulator.row_pop", 0, 1, False),
        ("tag", C + "u_accumulator.tag_head", 0, 16, False),
        ("acc_we", C + "u_accumulator.write_back_valid", 0, 1, False),
        ("acc_ow", C + "u_accumulator.write_back_overwrite", 0, 1, False),
        ("acc_waddr", C + "u_accumulator.write_back_address", 0, 16, False),
        ("accw", C + "u_accumulator.write_back_data", n, 32, True),
        ("accr", C + "ACC_read_data", n, 32, True),
        # ACT and the activation unit
        ("act_state", C + "u_activate_engine.state", 0, 3, False),
        ("act_addr", C + "u_activate_engine.read_address", 0, 16, False),
        ("act_rib", C + "u_activate_engine.row_in_block", 0, 9, False),
        ("act_blk", C + "u_activate_engine.block_index", 0, 11, False),
        ("act_par", C + "u_activate_engine.parameter_index", 0, 8, False),
        ("act_rq", C + "u_activate_engine.requantize", 0, 1, False),
        ("act_tub", C + "u_activate_engine.destination_is_UB", 0, 1, False),
        ("act_rdub", C + "u_activate_engine.is_read_UB", 0, 1, False),
        ("act_relu", C + "relu_enable", 0, 1, False),
        ("act_bias", C + "bias_enable", 0, 1, False),
        ("act_word", C + "u_activate_engine.word_index", 0, 8, False),
        ("act_ubdst", C + "u_activate_engine.UB_destination_address", 0, 16, False),
        ("abias", C + "bias_read_data", n, 32, True),
        ("aq", C + "quantization_read_data", n, 32, False),
        ("abiased", C + "biased_row", n, 32, True),
        ("alatch", C + "activation_row", n, 32, True),
        ("ares", C + "u_activate_engine.result_row", n, 32, True),
        ("aprod", C + "u_activation.product_row", n, 52, True),
        ("aquant", C + "quantized_row", n, 8, True),
        ("act_ubwe", C + "activate_UB_write_enable", 0, 1, False),
        ("act_ubaddr", C + "activate_UB_write_address", 0, 32, False),
        ("aub", C + "activate_UB_write_data", n, 8, True),
        ("out_push", C + "output_push", 0, 1, False),
        ("out_word", C + "activate_output_word", 0, 32, True),
        ("out_n", C + "output_occupancy", 0, 11, False),
        ("perf_beat", C + "performance_beat", 0, 1, False),
        ("perf_wstall", C + "performance_weight_stall", 0, 1, False),
    ]
    out = []
    for item in s:
        if item[0] == "cq":
            for c in range(n):
                out.append((f"cq{c}", C + f"u_accumulator.g_column[{c}].u_column.data_count", 0, 32, False))
            continue
        out.append(item)
    for r in range(n):
        for c in range(n):
            pe = C + f"u_mmu.g_row[{r}].g_column[{c}].u_pe."
            out += [(f"p{r}_{c}_a", pe + "activation_in", 0, 8, True),
                    (f"p{r}_{c}_v", pe + "activation_valid_in", 0, 1, False),
                    (f"p{r}_{c}_f", pe + "weight_flip_in", 0, 1, False),
                    (f"p{r}_{c}_pin", pe + "partial_sum_in", 0, 32, True),
                    (f"p{r}_{c}_ws", pe + "weight_valid_in", 0, 1, False),
                    (f"p{r}_{c}_wd", pe + "weight_in", 0, 8, True),
                    (f"p{r}_{c}_wc", pe + "weight_current", 0, 8, True),
                    (f"p{r}_{c}_wn", pe + "weight_next", 0, 8, True)]
    return out


def _signed(v, w):
    return v - (1 << w) if v >> (w - 1) & 1 else v


def _bits(s):
    """a VCD value; x and z read as 0 (reset, or never driven)"""
    if "x" in s or "z" in s or "X" in s or "Z" in s:
        s = s.replace("x", "0").replace("z", "0").replace("X", "0").replace("Z", "0")
    return int(s, 2) if s else 0


def read_vcd(path, n):
    """-> (keys, rows, first cycle): every key in _spec, one row per cycle"""
    spec = _spec(n)
    keys, decoders = [], {}          # VCD path -> [(column, lane, width, signed)]
    for key, vpath, lanes, width, signed in spec:
        if lanes:
            for lane in range(lanes):
                decoders.setdefault(vpath, []).append((len(keys), lane, width, signed))
                keys.append(f"{key}{lane}")
        else:
            decoders.setdefault(vpath, []).append((len(keys), None, width, signed))
            keys.append(key)

    by_id = {}
    scope = []
    cur = [0] * len(keys)
    rows, t_first, t_last = [], None, None

    def apply(vid, raw):
        v = _bits(raw)
        for col, lane, width, signed in by_id[vid]:
            x = (v >> (lane * width)) & ((1 << width) - 1) if lane is not None else v & ((1 << width) - 1)
            cur[col] = _signed(x, width) if signed else x

    def emit_until(t):
        nonlocal t_last
        if t_last is not None:
            while t_last < t:          # cycles with no change repeat the last record
                rows.append(cur.copy())
                t_last += 1

    with open(path) as fh:
        header = True
        for line in fh:
            if header:
                p = line.split()
                if not p:
                    continue
                if p[0] == "$scope":
                    scope.append(p[2])
                elif p[0] == "$upscope":
                    scope.pop()
                elif p[0] == "$var":
                    full = ".".join(scope[1:] + [p[4]])     # drop TOP
                    if full in decoders:
                        by_id.setdefault(p[3], []).extend(decoders[full])
                elif p[0] == "$enddefinitions":
                    header = False
                continue
            c = line[0]
            if c == "#":
                t = int(line[1:])
                if t_first is None:
                    t_first = t_last = t
                else:
                    emit_until(t)
            elif c in "bB":
                raw, vid = line[1:].split()
                if vid in by_id:
                    apply(vid, raw)
            elif c in "01xzXZ":
                vid = line[1:].strip()
                if vid in by_id:
                    apply(vid, c)
    if t_last is not None:
        rows.append(cur.copy())
    found = {k for ids in by_id.values() for k, *_ in ids}
    lost = [keys[i] for i in range(len(keys)) if i not in found]
    if lost:
        raise ValueError(f"{path}: signals not in the VCD (RTL renamed?): {', '.join(lost[:12])}")
    return keys, rows, t_first or 0


def delta_rows(rows):
    """rows -> the first in full, then [column, value, ...] for what changed: the
    page rebuilds full rows on load"""
    if not rows:
        return []
    out, prev = [rows[0]], rows[0]
    for r in rows[1:]:
        d = []
        for i, (a, b) in enumerate(zip(prev, r)):
            if a != b:
                d += (i, b)
        out.append(d)
        prev = r
    return out
