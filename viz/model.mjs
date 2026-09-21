// A cycle-accurate JavaScript model of the TPU datapath.
//
// Why this exists: the viewer lets you type in your own matrices, so the
// trace has to be computed on demand, in the browser. Running the real RTL
// there would mean an emscripten/WASM build; this is a faithful port instead.
//
// "Faithful" is a testable claim, not a hope. viz/check_model.mjs runs random
// matrices through both this and the actual Verilator model and compares every
// register, every cycle. If they ever diverge, that test fails.
//
// Two things keep the port honest:
//   * The control schedule below is not invented -- it was measured from an
//     RTL trace. The sequencer's FSM is counter-driven, so that schedule
//     depends only on the array shape, never on the data.
//   * Every register here mirrors one in rtl/: pe.sv's weight_reg and the
//     registered out_* ports, systolic_data_setup.sv's per-row shift chains,
//     accumulator.sv's column FIFOs and persistent psum, bias.sv, activation.sv.

const PSUM_BITS = 16;

/** Wrap to signed PSUM_BITS -- the accumulator does NOT saturate. */
function wrap(v) {
  const m = 1 << PSUM_BITS;
  let x = ((v % m) + m) % m;
  return x >= m / 2 ? x - m : x;
}

const grid = (r, c, v) => Array.from({ length: r }, () => new Array(c).fill(v));

/**
 * Control schedule, measured from rtl/tpu_sequencer.sv via viz/trace_tb.cpp.
 * t is relative to the first loading_phase cycle.
 *
 *   t = 0 .. R      loading_phase high (R+1 cycles)
 *   t = 1 .. R      weight_fifo presents one row per cycle, BOTTOM-FIRST
 *                   (docs/architecture.md section 5 -- each PE must capture
 *                   the top-row weight one cycle after the bottom-row one)
 *   t = R+1 .. R+M  unified_buffer read enable, addresses 0..M-1
 *   unified_buffer read latency is 2 cycles, so activations reach the array
 *   at t = R+3.
 */
export function schedule(R, M) {
  return {
    loadingFrom: 0, loadingTo: R,
    weightFrom: 1, weightTo: R,
    ubFrom: R + 1, ubTo: R + M,
    ubLatency: 2,
  };
}

/**
 * Run one RUN_TILE pass.
 *   W    rows x cols int8, natural row-major
 *   A    mTile x rows int8, natural row-major
 *   bias cols int16
 * Returns frames shaped exactly like viz/vcd_to_trace.py's JSON, so the two
 * can be compared field by field.
 */
export function simulate(W, A, bias, shape, opts = {}) {
  const R = shape.rows, C = shape.cols, M = shape.m_tile ?? shape.mTile;
  const sch = schedule(R, M);
  const lead = opts.lead ?? 2;                 // idle cycles before the action
  const tail = opts.tail ?? 8;                 // let the pipeline drain
  const total = lead + sch.ubTo + sch.ubLatency + R + C + tail;

  // ---- registers (all updated simultaneously at each edge) ----
  const wreg = grid(R, C, 0);                       // pe.weight_reg
  let actO = grid(R, C, 0), actOV = grid(R, C, 0);  // pe.out_activation(_valid)
  let psO = grid(R, C, 0), psOV = grid(R, C, 0);    // pe.out_partial_sum(_valid)
  let wO = grid(R, C, 0), wOV = grid(R, C, 0);      // pe.out_weight(_valid)
  // systolic_data_setup: row i has i delay stages; row 0 is combinational.
  const sdsD = Array.from({ length: R }, (_, i) => new Array(i).fill(0));
  const sdsV = Array.from({ length: R }, (_, i) => new Array(i).fill(0));
  const fifo = Array.from({ length: C }, () => []);
  const psumReg = grid(M, C, 0);
  let rowIdx = 0;
  let outRow = new Array(C).fill(0), outRowV = 0;
  let biRow = new Array(C).fill(0), biV = 0;
  let atRow = new Array(C).fill(0), atV = 0;

  const frames = [];

  for (let c = 0; c < total; c++) {
    const t = c - lead;                      // schedule-relative cycle
    const loading = t >= sch.loadingFrom && t <= sch.loadingTo ? 1 : 0;

    // ---- weight_fifo drain: one row per cycle, bottom-first ----
    const wfCol = new Array(C).fill(0);
    const wfV = new Array(C).fill(0);
    if (t >= sch.weightFrom && t <= sch.weightTo) {
      const k = t - sch.weightFrom;          // 0-based presentation index
      const srcRow = R - 1 - k;              // bottom-first
      for (let j = 0; j < C; j++) { wfCol[j] = W[srcRow][j]; wfV[j] = 1; }
    }

    // ---- unified_buffer: read enable now, data 2 cycles later ----
    const ubT = t - sch.ubLatency;
    const ubValid = ubT >= sch.ubFrom && ubT <= sch.ubTo ? 1 : 0;
    const ubAddr = ubValid ? ubT - sch.ubFrom : 0;
    const ubData = new Array(R).fill(0);
    if (ubValid) for (let i = 0; i < R; i++) ubData[i] = A[ubAddr][i];
    const ubEn = t >= sch.ubFrom && t <= sch.ubTo ? 1 : 0;
    const ubEnAddr = ubEn ? t - sch.ubFrom : 0;

    // ---- SDS outputs (row 0 combinational, row i = i-deep shift) ----
    const sdsOut = new Array(R).fill(0), sdsOutV = new Array(R).fill(0);
    for (let i = 0; i < R; i++) {
      if (i === 0) { sdsOut[i] = ubData[i]; sdsOutV[i] = ubValid; }
      else { sdsOut[i] = sdsD[i][i - 1]; sdsOutV[i] = sdsV[i][i - 1]; }
    }

    // ---- PE combinational inputs ----
    const inAct = grid(R, C, 0), inActV = grid(R, C, 0);
    const inPs = grid(R, C, 0), inPsV = grid(R, C, 0);
    const inW = grid(R, C, 0), inWV = grid(R, C, 0);
    for (let r = 0; r < R; r++) {
      for (let j = 0; j < C; j++) {
        inAct[r][j] = j === 0 ? sdsOut[r] : actO[r][j - 1];
        inActV[r][j] = j === 0 ? sdsOutV[r] : actOV[r][j - 1];
        inPs[r][j] = r === 0 ? 0 : psO[r - 1][j];
        inPsV[r][j] = r === 0 ? 0 : psOV[r - 1][j];
        inW[r][j] = r === 0 ? wfCol[j] : wO[r - 1][j];
        inWV[r][j] = r === 0 ? wfV[j] : wOV[r - 1][j];
      }
    }

    // ---- emit this cycle's frame BEFORE advancing state ----
    frames.push({
      c,
      state: loading ? "LOADING"
           : (ubEn ? "STREAM"
           : (t > sch.ubTo ? "WAIT" : (t >= 0 ? "LD_WF" : "IDLE"))),
      loading,
      sds: { row: sdsOut.slice(), valid: sdsOutV.slice() },
      wf: { col: wfCol.slice(), valid: wfV.slice() },
      ub: { data: ubData.slice(), valid: ubValid, addr: ubEnAddr, en: ubEn },
      accum: { row: outRow.slice(), valid: outRowV },
      bias: { row: biRow.slice(), valid: biV },
      act: { row: atRow.slice(), valid: atV },
      pe: Array.from({ length: R }, (_, r) =>
        Array.from({ length: C }, (_, j) => ({
          w: wreg[r][j], a: inAct[r][j], av: inActV[r][j],
          p: psO[r][j], pv: psOV[r][j],
        }))),
    });

    // ================= next state =================
    const nActO = grid(R, C, 0), nActOV = grid(R, C, 0);
    const nPsO = grid(R, C, 0), nPsOV = grid(R, C, 0);
    const nWO = grid(R, C, 0), nWOV = grid(R, C, 0);
    for (let r = 0; r < R; r++) {
      for (let j = 0; j < C; j++) {
        if (loading) {
          nWO[r][j] = inW[r][j];
          nWOV[r][j] = inWV[r][j];
          // capture_weight_col[c] is the weight_fifo's own out_col_valid
          if (wfV[j] && inWV[r][j]) wreg[r][j] = inW[r][j];
          // activation/psum path held idle while weights propagate
          nActO[r][j] = 0; nActOV[r][j] = 0;
          nPsO[r][j] = 0; nPsOV[r][j] = 0;
        } else {
          nWO[r][j] = 0; nWOV[r][j] = 0;
          nActO[r][j] = inAct[r][j];
          nActOV[r][j] = inActV[r][j];
          if (inActV[r][j]) {
            nPsO[r][j] = wrap(wreg[r][j] * inAct[r][j] +
                              (inPsV[r][j] ? inPs[r][j] : 0));
            nPsOV[r][j] = 1;
          } else {
            nPsO[r][j] = inPs[r][j];
            nPsOV[r][j] = inPsV[r][j];
          }
        }
      }
    }

    // SDS shift chains
    for (let i = 1; i < R; i++) {
      for (let j = i - 1; j > 0; j--) { sdsD[i][j] = sdsD[i][j - 1]; sdsV[i][j] = sdsV[i][j - 1]; }
      sdsD[i][0] = ubData[i]; sdsV[i][0] = ubValid;
    }

    // Accumulator: push this cycle's bottom-row psums, pop a row when every
    // column FIFO has one (accumulator.sv's lockstep pop_row gate).
    const popRow = fifo.every((q) => q.length > 0);
    const rd = popRow ? fifo.map((q) => q[0]) : null;
    let nOutRow = outRow.slice(), nOutRowV = 0;
    if (popRow) {
      for (let j = 0; j < C; j++) {
        // tile_first=1 and tile_last=1 for a single-tile RUN_TILE.
        psumReg[rowIdx][j] = rd[j];
        nOutRow[j] = rd[j];
      }
      nOutRowV = 1;
      rowIdx = rowIdx === M - 1 ? 0 : rowIdx + 1;
    }
    for (let j = 0; j < C; j++) {
      if (popRow) fifo[j].shift();
      if (psOV[R - 1][j]) fifo[j].push(psO[R - 1][j]);
    }

    const nBiRow = biRow.slice();
    const nBiV = outRowV;
    if (outRowV) for (let j = 0; j < C; j++) nBiRow[j] = wrap(outRow[j] + bias[j]);

    const nAtRow = atRow.slice();
    const nAtV = biV;
    if (biV) for (let j = 0; j < C; j++) nAtRow[j] = biRow[j] < 0 ? 0 : biRow[j];

    actO = nActO; actOV = nActOV; psO = nPsO; psOV = nPsOV;
    wO = nWO; wOV = nWOV;
    outRow = nOutRow; outRowV = nOutRowV;
    biRow = nBiRow; biV = nBiV;
    atRow = nAtRow; atV = nAtV;
  }

  return { shape: { rows: R, cols: C, m_tile: M }, cycles: frames };
}

/** Reference result: what the hardware should produce, computed directly. */
export function golden(W, A, bias, shape) {
  const R = shape.rows, C = shape.cols, M = shape.m_tile ?? shape.mTile;
  const out = grid(M, C, 0);
  for (let m = 0; m < M; m++)
    for (let j = 0; j < C; j++) {
      let s = bias[j];
      for (let k = 0; k < R; k++) s += A[m][k] * W[k][j];
      const w = wrap(s);
      out[m][j] = w < 0 ? 0 : w;
    }
  return out;
}
