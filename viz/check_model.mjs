// check_model -- prove viz/model.mjs matches the actual RTL, cycle for cycle.
//
//   node viz/check_model.mjs [--n 25] [--seed 1] [--verbose]
//
// For each random (W, A, bias):
//   1. run the Verilator trace harness (the real rtl/) -> VCD
//   2. viz/vcd_to_trace.py -> per-cycle JSON
//   3. run viz/model.mjs on the same inputs
//   4. align on the first loading_phase cycle and compare every register
//
// A mismatch prints the first differing cycle and field. This is the test
// that makes the viewer trustworthy: without it the animation is just a
// plausible-looking cartoon.
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { simulate, golden } from "./model.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const HARNESS = join(ROOT, "sim/verilator/trace/trace_tb");
const EXTRACT = join(HERE, "vcd_to_trace.py");
const PY = process.env.VIZ_PYTHON ||
           (existsSyncSafe(join(ROOT, "bin/python3")) ? join(ROOT, "bin/python3") : "python3");

function existsSyncSafe(p) {
  try { readFileSync(p); return true; } catch { return false; }
}

const argv = process.argv.slice(2);
const argOf = (k, d) => {
  const i = argv.indexOf(k);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : d;
};
const N = parseInt(argOf("--n", "25"), 10);
const VERBOSE = argv.includes("--verbose");
let seed = parseInt(argOf("--seed", "1"), 10);

// Deterministic PRNG so a failure is always reproducible from its seed.
function rnd() {
  seed = (seed * 1664525 + 1013904223) >>> 0;
  return seed / 4294967296;
}
const randInt = (lo, hi) => lo + Math.floor(rnd() * (hi - lo + 1));

const SHAPE = { rows: 4, cols: 4, m_tile: 4 };
const { rows: R, cols: C, m_tile: M } = SHAPE;

function firstLoading(cycles) {
  return cycles.findIndex((f) => f.loading === 1);
}

const FAIL_LIMIT = 6;

function compare(rtl, js) {
  const oR = firstLoading(rtl.cycles), oJ = firstLoading(js.cycles);
  if (oR < 0 || oJ < 0) return [`no loading_phase found (rtl ${oR}, js ${oJ})`];
  const problems = [];
  const n = Math.min(rtl.cycles.length - oR, js.cycles.length - oJ);
  for (let k = 0; k < n && problems.length < FAIL_LIMIT; k++) {
    const a = rtl.cycles[oR + k], b = js.cycles[oJ + k];
    const at = (msg) => `cycle +${k} (rtl ${a.c}): ${msg}`;
    const eqArr = (x, y) => x.length === y.length && x.every((v, i) => v === y[i]);

    if (a.loading !== b.loading) problems.push(at(`loading ${a.loading} vs ${b.loading}`));
    for (const key of ["sds", "wf"]) {
      const fa = key === "sds" ? a.sds.row : a.wf.col;
      const fb = key === "sds" ? b.sds.row : b.wf.col;
      const va = key === "sds" ? a.sds.valid : a.wf.valid;
      const vb = key === "sds" ? b.sds.valid : b.wf.valid;
      if (!eqArr(va, vb)) problems.push(at(`${key}.valid [${va}] vs [${vb}]`));
      // Data only has to match where it is flagged valid; the RTL leaves
      // stale bytes on the bus otherwise and so may we.
      for (let i = 0; i < fa.length; i++)
        if (va[i] && fa[i] !== fb[i])
          problems.push(at(`${key}.data[${i}] ${fa[i]} vs ${fb[i]}`));
    }
    for (const key of ["accum", "bias", "act"]) {
      if (a[key].valid !== b[key].valid)
        problems.push(at(`${key}.valid ${a[key].valid} vs ${b[key].valid}`));
      if (a[key].valid && !eqArr(a[key].row, b[key].row))
        problems.push(at(`${key}.row [${a[key].row}] vs [${b[key].row}]`));
    }
    for (let r = 0; r < R; r++)
      for (let c2 = 0; c2 < C; c2++) {
        const pa = a.pe[r][c2], pb = b.pe[r][c2];
        if (pa.w !== pb.w) problems.push(at(`pe[${r}][${c2}].weight ${pa.w} vs ${pb.w}`));
        if (pa.av !== pb.av) problems.push(at(`pe[${r}][${c2}].act_valid ${pa.av} vs ${pb.av}`));
        if (pa.av && pa.a !== pb.a) problems.push(at(`pe[${r}][${c2}].act ${pa.a} vs ${pb.a}`));
        if (pa.pv !== pb.pv) problems.push(at(`pe[${r}][${c2}].psum_valid ${pa.pv} vs ${pb.pv}`));
        if (pa.pv && pa.p !== pb.p) problems.push(at(`pe[${r}][${c2}].psum ${pa.p} vs ${pb.p}`));
      }
  }
  return problems;
}

const dir = mkdtempSync(join(tmpdir(), "vizchk-"));
let pass = 0, fail = 0;
try {
  for (let it = 0; it < N; it++) {
    const W = Array.from({ length: R }, () => Array.from({ length: C }, () => randInt(-128, 127)));
    const A = Array.from({ length: M }, () => Array.from({ length: R }, () => randInt(-128, 127)));
    const bias = Array.from({ length: C }, () => randInt(-2000, 2000));

    const vcd = join(dir, `t${it}.vcd`);
    const meta = execFileSync(HARNESS, [
      "--w", W.flat().join(","), "--a", A.flat().join(","),
      "--bias", bias.join(","), "-o", vcd,
    ]).toString().trim();
    const jsonPath = join(dir, `t${it}.json`);
    execFileSync(PY, [EXTRACT, vcd, "-o", jsonPath,
                      "--rows", String(R), "--cols", String(C),
                      "--m-tile", String(M)], { stdio: "pipe" });

    const rtl = JSON.parse(readFileSync(jsonPath, "utf8"));
    const js = simulate(W, A, bias, SHAPE);

    const problems = compare(rtl, js);

    // The device's own answer must also equal the reference -- a model that
    // matched a broken trace would be no use.
    const devResult = JSON.parse(meta).result;
    const want = golden(W, A, bias, SHAPE).flat();
    if (devResult.join(",") !== want.join(","))
      problems.push(`device result [${devResult}] != golden [${want}]`);

    if (problems.length === 0) {
      pass++;
      if (VERBOSE) console.log(`  [${it}] ok`);
    } else {
      fail++;
      console.log(`  [${it}] MISMATCH (seed-derived case ${it})`);
      for (const p of problems) console.log(`      ${p}`);
      if (fail >= 3) break;
    }
  }
} finally {
  rmSync(dir, { recursive: true, force: true });
}

console.log(`\nviz model vs RTL: ${pass}/${pass + fail} cases matched cycle-for-cycle`);
process.exit(fail === 0 ? 0 : 1);
