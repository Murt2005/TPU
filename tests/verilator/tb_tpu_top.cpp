// Verilator C++ testbench for tpu_top -- the WHOLE chip, driven through its
// real UART pins at the hardware CLK_FREQ/BAUD_RATE ratio (12 MHz / 1 Mbaud,
// TICKS_PER_BIT = 12). This exercises the exact stack real silicon sees
// (uart_rx bit sampling -> sequencer -> datapath -> uart_tx bit shifting),
// which none of the Icarus testbenches do: tpu_sequencer_tb injects
// rx_data/rx_valid behind the UART.
//
// The test set mirrors tests/hw_regression.py (fixed pattern cases, reset
// roundtrip, unknown CMD, randomized stress, matmul_tiled stress, RUN_TILE
// equivalence, STREAM_RUN frame boundaries) plus one case only simulation
// can do: injecting a UART framing error (bad stop bit) and checking the
// sequencer answers STATUS_ERR and recovers.
//
// Build/run at any shape via `make verilate-test` (root Makefile): the array
// shape is chparam'd with -GARRAY_ROWS/-GNUM_COLS/-GM_TILE and mirrored to
// this file with -DTB_ROWS/-DTB_COLS/-DTB_MTILE.

#include <cstdint>
#include <cstdio>
#include <memory>
#include <random>
#include <vector>

#include "Vtpu_top.h"
#include "verilated.h"

#ifndef TB_ROWS
#define TB_ROWS 2
#endif
#ifndef TB_COLS
#define TB_COLS 2
#endif
#ifndef TB_MTILE
#define TB_MTILE 2
#endif

// Must match the -GCLK_FREQ/-GBAUD_RATE the model was verilated with.
static constexpr int TICKS_PER_BIT = 12;

static constexpr int ROWS   = TB_ROWS;   // ARRAY_ROWS: K-tile depth
static constexpr int COLS   = TB_COLS;   // NUM_COLS:   N-tile width
static constexpr int MTILE  = TB_MTILE;  // M rows per RUN

static constexpr int W_BYTES      = ROWS * COLS;
static constexpr int A_BYTES      = MTILE * ROWS;
static constexpr int RESULT_BYTES = 2 * MTILE * COLS;
static constexpr int TILE_BYTES   = W_BYTES + A_BYTES;
static constexpr int MAX_STREAM_TILES = (255 - 2) / TILE_BYTES;

static constexpr uint8_t CMD_LOAD_WEIGHTS = 0x01;
static constexpr uint8_t CMD_LOAD_BIAS    = 0x02;
static constexpr uint8_t CMD_LOAD_ACT     = 0x03;
static constexpr uint8_t CMD_RUN          = 0x04;
static constexpr uint8_t CMD_RESET        = 0x05;
static constexpr uint8_t CMD_RUN_TILE     = 0x06;
static constexpr uint8_t CMD_STREAM_RUN   = 0x07;

static constexpr int STATUS_OK  = 0xAA;
static constexpr int STATUS_ERR = 0xFF;

using Mat  = std::vector<std::vector<int>>;      // int8/int16 values as int
using Vec  = std::vector<int>;
using Bytes = std::vector<uint8_t>;

// ---------------------------------------------------------------------------
// Golden model -- must match tests/hw_regression.py golden(): the
// accumulator/bias sum wraps silently at int16 (non-saturating), and ReLU is
// applied AFTER that truncation.
// ---------------------------------------------------------------------------
static Mat golden(const Mat& a, const Mat& w, const Vec& bias) {
    size_t m = a.size(), k = w.size(), n = w[0].size();
    Mat out(m, std::vector<int>(n));
    for (size_t i = 0; i < m; i++) {
        for (size_t j = 0; j < n; j++) {
            long long s = bias[j];
            for (size_t x = 0; x < k; x++) s += (long long)a[i][x] * w[x][j];
            int16_t wrapped = (int16_t)(uint16_t)(s & 0xFFFF);
            out[i][j] = wrapped > 0 ? wrapped : 0;
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// UART bus-functional model around the verilated tpu_top
// ---------------------------------------------------------------------------
struct Tb {
    std::unique_ptr<Vtpu_top> dut{new Vtpu_top};
    uint64_t cycles = 0;

    Tb() {
        dut->clk = 0;
        dut->reset_n = 1;
        dut->rx_pin = 1;  // UART idle high
        dut->eval();
        // tpu_top's power-on-reset generator holds internal reset for the
        // first 256 cycles; give it slack before talking.
        cycle(300);
    }

    void cycle(int n = 1) {
        for (int i = 0; i < n; i++) {
            dut->clk = 1; dut->eval();
            dut->clk = 0; dut->eval();
            cycles++;
        }
    }

    void send_bit(int b) { dut->rx_pin = b; cycle(TICKS_PER_BIT); }

    void send_byte(uint8_t v, bool good_stop = true) {
        send_bit(0);                                    // start
        for (int i = 0; i < 8; i++) send_bit((v >> i) & 1);  // LSB first
        send_bit(good_stop ? 1 : 0);                    // stop
        dut->rx_pin = 1;
        cycle(2);                                       // brief inter-byte idle
    }

    // Returns the received byte, or <0 on timeout/framing trouble at the BFM.
    int recv_byte(uint64_t timeout_cycles = 500000) {
        while (dut->tx_pin == 1) {
            cycle();
            if (--timeout_cycles == 0) return -1;       // no start bit seen
        }
        cycle(TICKS_PER_BIT / 2);                       // mid start bit
        if (dut->tx_pin != 0) return -2;
        uint8_t v = 0;
        for (int i = 0; i < 8; i++) {
            cycle(TICKS_PER_BIT);                       // mid data bit i
            v |= (uint8_t)dut->tx_pin << i;
        }
        cycle(TICKS_PER_BIT);                           // mid stop bit
        if (dut->tx_pin != 1) return -3;
        return v;
    }

    // Full command round trip. Returns status byte (or <0 on BFM timeout);
    // response payload lands in resp.
    int send_cmd(uint8_t cmd, const Bytes& payload, Bytes& resp) {
        send_byte(cmd);
        send_byte((uint8_t)payload.size());
        for (uint8_t b : payload) send_byte(b);
        int status = recv_byte();
        if (status < 0) return status;
        int len = recv_byte();
        if (len < 0) return len;
        resp.clear();
        for (int i = 0; i < len; i++) {
            int b = recv_byte();
            if (b < 0) return b;
            resp.push_back((uint8_t)b);
        }
        return status;
    }

    // -- protocol commands, mirroring tpu_host.py's TPU class --------------

    bool load_weights(const Mat& w) {   // (ROWS x COLS), bottom row first on the wire
        Bytes p;
        for (int r = ROWS - 1; r >= 0; r--)
            for (int c = 0; c < COLS; c++) p.push_back((uint8_t)(int8_t)w[r][c]);
        Bytes resp;
        return send_cmd(CMD_LOAD_WEIGHTS, p, resp) == STATUS_OK;
    }

    bool load_bias(const Vec& b) {      // COLS int16 LE
        Bytes p;
        for (int c = 0; c < COLS; c++) {
            uint16_t v = (uint16_t)(int16_t)b[c];
            p.push_back(v & 0xFF);
            p.push_back(v >> 8);
        }
        Bytes resp;
        return send_cmd(CMD_LOAD_BIAS, p, resp) == STATUS_OK;
    }

    bool load_activations(const Mat& a) {  // (MTILE x ROWS), row-major
        Bytes p;
        for (int m = 0; m < MTILE; m++)
            for (int k = 0; k < ROWS; k++) p.push_back((uint8_t)(int8_t)a[m][k]);
        Bytes resp;
        return send_cmd(CMD_LOAD_ACT, p, resp) == STATUS_OK;
    }

    static Mat parse_result(const Bytes& resp) {
        Mat out(MTILE, std::vector<int>(COLS));
        for (int m = 0; m < MTILE; m++)
            for (int c = 0; c < COLS; c++) {
                int idx = 2 * (m * COLS + c);
                out[m][c] = (int16_t)(resp[idx] | (resp[idx + 1] << 8));
            }
        return out;
    }

    // RUN with K-tiling flags; result valid only when last=true.
    bool run(Mat& result, bool first = true, bool last = true) {
        Bytes p;
        if (!(first && last))
            p.push_back((uint8_t)((first ? 1 : 0) | (last ? 2 : 0)));
        Bytes resp;
        if (send_cmd(CMD_RUN, p, resp) != STATUS_OK) return false;
        if (!last) return true;
        if ((int)resp.size() != RESULT_BYTES) return false;
        result = parse_result(resp);
        return true;
    }

    // RUN_TILE: weights in NATURAL row-major order on the wire.
    bool run_tile(const Mat& w, const Mat& a, Mat& result,
                  bool first = true, bool last = true) {
        Bytes p{(uint8_t)((first ? 1 : 0) | (last ? 2 : 0))};
        for (int r = 0; r < ROWS; r++)
            for (int c = 0; c < COLS; c++) p.push_back((uint8_t)(int8_t)w[r][c]);
        for (int m = 0; m < MTILE; m++)
            for (int k = 0; k < ROWS; k++) p.push_back((uint8_t)(int8_t)a[m][k]);
        Bytes resp;
        if (send_cmd(CMD_RUN_TILE, p, resp) != STATUS_OK) return false;
        if (!last) return true;
        if ((int)resp.size() != RESULT_BYTES) return false;
        result = parse_result(resp);
        return true;
    }

    // STREAM_RUN: up to MAX_STREAM_TILES (w, a) tile pairs in one frame.
    bool stream_run(const std::vector<Mat>& w_tiles, const std::vector<Mat>& a_tiles,
                    Mat& result, bool first, bool last) {
        Bytes p{(uint8_t)((first ? 1 : 0) | (last ? 2 : 0)),
                (uint8_t)w_tiles.size()};
        for (size_t t = 0; t < w_tiles.size(); t++) {
            for (int r = 0; r < ROWS; r++)
                for (int c = 0; c < COLS; c++)
                    p.push_back((uint8_t)(int8_t)w_tiles[t][r][c]);
            for (int m = 0; m < MTILE; m++)
                for (int k = 0; k < ROWS; k++)
                    p.push_back((uint8_t)(int8_t)a_tiles[t][m][k]);
        }
        Bytes resp;
        if (send_cmd(CMD_STREAM_RUN, p, resp) != STATUS_OK) return false;
        if (!last) return true;
        if ((int)resp.size() != RESULT_BYTES) return false;
        result = parse_result(resp);
        return true;
    }

    bool reset_cmd() {
        Bytes resp;
        return send_cmd(CMD_RESET, {}, resp) == STATUS_OK;
    }

    bool matmul(const Mat& a, const Mat& w, const Vec& bias, Mat& result) {
        return load_activations(a) && load_weights(w) && load_bias(bias) &&
               run(result);
    }

    // Port of tpu_host.py matmul_tiled(): any (M,K)x(K,N), zero-padded to
    // tile multiples, K-runs chunked into STREAM_RUN frames.
    bool matmul_tiled(const Mat& a, const Mat& w, const Vec& bias, Mat& out) {
        int M = (int)a.size(), K = (int)w.size(), N = (int)w[0].size();
        auto round_up = [](int x, int q) { return ((x + q - 1) / q) * q; };
        int mp = round_up(M, MTILE), kp = round_up(K, ROWS), np = round_up(N, COLS);

        auto at = [&](const Mat& mtx, int i, int j) {
            return (i < (int)mtx.size() && j < (int)mtx[0].size()) ? mtx[i][j] : 0;
        };
        out.assign(M, std::vector<int>(N, 0));
        int num_k_tiles = kp / ROWS;

        for (int m0 = 0; m0 < mp; m0 += MTILE) {
            for (int n0 = 0; n0 < np; n0 += COLS) {
                Vec b(COLS, 0);
                for (int c = 0; c < COLS; c++)
                    b[c] = (n0 + c < N) ? bias[n0 + c] : 0;
                if (!load_bias(b)) return false;

                std::vector<Mat> w_tiles, a_tiles;
                for (int k0 = 0; k0 < kp; k0 += ROWS) {
                    Mat wt(ROWS, std::vector<int>(COLS));
                    for (int r = 0; r < ROWS; r++)
                        for (int c = 0; c < COLS; c++) wt[r][c] = at(w, k0 + r, n0 + c);
                    Mat att(MTILE, std::vector<int>(ROWS));
                    for (int m = 0; m < MTILE; m++)
                        for (int k = 0; k < ROWS; k++) att[m][k] = at(a, m0 + m, k0 + k);
                    w_tiles.push_back(wt);
                    a_tiles.push_back(att);
                }

                Mat result;
                for (int c0 = 0; c0 < num_k_tiles; c0 += MAX_STREAM_TILES) {
                    int c1 = std::min(c0 + MAX_STREAM_TILES, num_k_tiles);
                    std::vector<Mat> wc(w_tiles.begin() + c0, w_tiles.begin() + c1);
                    std::vector<Mat> ac(a_tiles.begin() + c0, a_tiles.begin() + c1);
                    if (!stream_run(wc, ac, result, c0 == 0, c1 == num_k_tiles))
                        return false;
                }
                for (int m = 0; m < MTILE && m0 + m < M; m++)
                    for (int c = 0; c < COLS && n0 + c < N; c++)
                        out[m0 + m][n0 + c] = result[m][c];
            }
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// Test harness bookkeeping
// ---------------------------------------------------------------------------
static int g_pass = 0, g_fail = 0;

static void report(bool ok, const char* name) {
    printf("[%s] %s\n", ok ? "PASS" : "FAIL", name);
    (ok ? g_pass : g_fail)++;
}

static bool eq(const Mat& a, const Mat& b) { return a == b; }

static void dump(const char* tag, const Mat& m) {
    printf("       %s=[", tag);
    for (auto& row : m) {
        printf("[");
        for (int v : row) printf("%d,", v);
        printf("]");
    }
    printf("]\n");
}

static bool check_case(Tb& tb, const char* name, const Mat& a, const Mat& w,
                       const Vec& bias) {
    Mat expected = golden(a, w, bias), got;
    bool ok = tb.matmul(a, w, bias, got) && eq(got, expected);
    report(ok, name);
    if (!ok) { dump("got", got); dump("expected", expected); }
    return ok;
}

// Deterministic random helpers (fixed seeds -> reproducible failures)
static Mat rand_mat(std::mt19937& rng, int r, int c, int lo, int hi) {
    std::uniform_int_distribution<int> d(lo, hi);
    Mat m(r, std::vector<int>(c));
    for (auto& row : m) for (int& v : row) v = d(rng);
    return m;
}
static Vec rand_vec(std::mt19937& rng, int n, int lo, int hi) {
    std::uniform_int_distribution<int> d(lo, hi);
    Vec v(n);
    for (int& x : v) x = d(rng);
    return v;
}

// The seven fixed case patterns from tests/hw_regression.py, generated at
// this build's shape (exact 2x2 vectors when the shape is 2x2/M_TILE=2).
static std::vector<std::tuple<const char*, Mat, Mat, Vec>> build_cases() {
    if (ROWS == 2 && COLS == 2 && MTILE == 2) {
        return {
            {"T1 happy path", {{1, 2}, {3, 4}}, {{4, 5}, {2, 3}}, {100, 200}},
            {"T2 zero weights + negative bias -> all zero",
             {{0, 0}, {0, 0}}, {{0, 0}, {0, 0}}, {-10, -20}},
            {"T5 negative arithmetic + ReLU clamp",
             {{-1, 1}, {2, -2}}, {{-1, -2}, {-3, -4}}, {0, 0}},
            {"T6 identity matrix", {{10, 20}, {30, 40}}, {{1, 0}, {0, 1}}, {0, 0}},
            {"int8 max positive squared",
             {{127, 127}, {127, 127}}, {{127, 0}, {0, 127}}, {0, 0}},
            {"int8 min negative squared",
             {{-128, -128}, {-128, -128}}, {{-128, 0}, {0, -128}}, {0, 0}},
            {"mixed extremes -- PSUM_WIDTH overflow wraparound",
             {{127, -128}, {-128, 127}}, {{-128, 127}, {127, -128}}, {1000, -1000}},
        };
    }
    std::mt19937 rng(1234);
    Mat a_rand = rand_mat(rng, MTILE, ROWS, 1, 8);
    Mat w_rand = rand_mat(rng, ROWS, COLS, 1, 8);
    Vec b_alt(COLS);
    for (int c = 0; c < COLS; c++) b_alt[c] = 100 * (c % 2 == 0 ? 1 : 2);
    Mat w_sel(ROWS, std::vector<int>(COLS, 0));       // one-hot weight columns
    for (int c = 0; c < COLS; c++) w_sel[c % ROWS][c] = 1;
    auto scale = [](const Mat& m, int s) {
        Mat r = m;
        for (auto& row : r) for (int& v : row) v *= s;
        return r;
    };
    Mat signs(MTILE, std::vector<int>(ROWS)), wsigns(ROWS, std::vector<int>(COLS));
    for (int i = 0; i < MTILE; i++)
        for (int j = 0; j < ROWS; j++) signs[i][j] = ((i + j) % 2 == 0) ? 1 : -1;
    for (int i = 0; i < ROWS; i++)
        for (int j = 0; j < COLS; j++) wsigns[i][j] = ((i + j) % 2 == 0) ? 1 : -1;
    Mat a_signed = a_rand, w_neg = w_rand;
    for (int i = 0; i < MTILE; i++)
        for (int j = 0; j < ROWS; j++) a_signed[i][j] *= signs[i][j];
    for (auto& row : w_neg) for (int& v : row) v = -std::abs(v);
    Vec b_neg(COLS), b_zero(COLS, 0), b_alt2(COLS);
    for (int c = 0; c < COLS; c++) b_neg[c] = -10 * (c + 1);
    for (int c = 0; c < COLS; c++) b_alt2[c] = (c % 2 == 0) ? 1000 : -1000;
    Mat extremes_a = signs, extremes_w = wsigns;      // ±127 / -128 pattern
    for (auto& row : extremes_a) for (int& v : row) v = v > 0 ? 127 : -128;
    for (auto& row : extremes_w) for (int& v : row) v = v > 0 ? 127 : -128;
    return {
        {"T1 happy path", a_rand, w_rand, b_alt},
        {"T2 zero weights + negative bias -> all zero",
         Mat(MTILE, std::vector<int>(ROWS, 0)), Mat(ROWS, std::vector<int>(COLS, 0)), b_neg},
        {"T5 negative arithmetic + ReLU clamp", a_signed, w_neg, b_zero},
        {"T6 selection matrix (one-hot weight columns)", scale(a_rand, 10), w_sel, b_zero},
        {"int8 max positive squared",
         Mat(MTILE, std::vector<int>(ROWS, 127)), scale(w_sel, 127), b_zero},
        {"int8 min negative squared",
         Mat(MTILE, std::vector<int>(ROWS, -128)), scale(w_sel, -128), b_zero},
        {"mixed extremes -- PSUM_WIDTH overflow wraparound",
         extremes_a, extremes_w, b_alt2},
    };
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    printf("=== tb_tpu_top: %dx%d array, M_TILE=%d (TICKS_PER_BIT=%d) ===\n",
           ROWS, COLS, MTILE, TICKS_PER_BIT);
    Tb tb;

    // 1) Fixed pattern cases (the hw_regression.py seven)
    auto cases = build_cases();
    for (auto& [name, a, w, b] : cases) check_case(tb, name, a, w, b);

    // 2) Reset roundtrip: CMD_RESET, then the first case must still pass
    {
        bool ok = tb.reset_cmd();
        auto& [name, a, w, b] = cases[0];
        Mat expected = golden(a, w, b), got;
        ok = ok && tb.matmul(a, w, b, got) && eq(got, expected);
        report(ok, "T3b post-reset compute");
    }

    // 3) Unknown CMD 0xFF -> STATUS_ERR
    {
        Bytes resp;
        int status = tb.send_cmd(0xFF, {}, resp);
        report(status == STATUS_ERR && resp.empty(), "T4 unknown CMD 0xFF -> STATUS_ERR");
    }

    // 4) UART framing error (bad stop bit) -> STATUS_ERR, then full recovery.
    //    Only possible in simulation -- the BFM breaks the stop bit on what
    //    the sequencer expects to be a CMD byte.
    {
        tb.send_byte(CMD_RUN, /*good_stop=*/false);
        int status = tb.recv_byte();
        int len = tb.recv_byte();
        bool ok = (status == STATUS_ERR && len == 0);
        auto& [name, a, w, b] = cases[0];
        Mat expected = golden(a, w, b), got;
        ok = ok && tb.matmul(a, w, b, got) && eq(got, expected);
        report(ok, "T4b framing error -> STATUS_ERR + recovery");
    }

    // 5) Randomized single-tile stress vs golden (legacy command path)
    {
        std::mt19937 rng(0);
        int n = 100, fails = 0;
        for (int i = 0; i < n; i++) {
            Mat a = rand_mat(rng, MTILE, ROWS, -128, 127);
            Mat w = rand_mat(rng, ROWS, COLS, -128, 127);
            Vec b = rand_vec(rng, COLS, -1000, 999);
            Mat expected = golden(a, w, b), got;
            if (!(tb.matmul(a, w, b, got) && eq(got, expected))) {
                if (fails++ == 0) { dump("a", a); dump("w", w); dump("got", got); dump("expected", expected); }
            }
        }
        char buf[96];
        snprintf(buf, sizeof buf, "stress: %d/%d randomized matmuls matched golden", n - fails, n);
        report(fails == 0, buf);
    }

    // 6) RUN_TILE equivalence: one frame must be bit-identical to the legacy
    //    LOAD_WEIGHTS/LOAD_ACT/RUN triple (and to golden)
    {
        std::mt19937 rng(1);
        int n = 25, fails = 0;
        for (int i = 0; i < n; i++) {
            Mat a = rand_mat(rng, MTILE, ROWS, -128, 127);
            Mat w = rand_mat(rng, ROWS, COLS, -128, 127);
            Vec b = rand_vec(rng, COLS, -1000, 999);
            Mat legacy, via_tile;
            bool ok = tb.matmul(a, w, b, legacy);        // loads bias as a side effect...
            ok = ok && tb.run_tile(w, a, via_tile);      // ...which persists for RUN_TILE
            if (!(ok && eq(legacy, via_tile) && eq(via_tile, golden(a, w, b)))) fails++;
        }
        char buf[96];
        snprintf(buf, sizeof buf, "run_tile equivalence: %d/%d matched legacy + golden", n - fails, n);
        report(fails == 0, buf);
    }

    // 7) matmul_tiled stress: random M/K/N incl. non-multiples of the tile
    //    (exercises zero-padding + hardware K-accumulation via STREAM_RUN)
    {
        std::mt19937 rng(2);
        int n = 25, fails = 0;
        int m_choices[] = {1, MTILE, 2 * MTILE, 2 * MTILE + 1};
        int k_choices[] = {ROWS, 2 * ROWS, 3 * ROWS, 3 * ROWS + 1};
        int n_choices[] = {COLS, 2 * COLS, 2 * COLS + 1, 3 * COLS - 1};
        std::uniform_int_distribution<int> pick(0, 3);
        for (int i = 0; i < n; i++) {
            int M = m_choices[pick(rng)], K = k_choices[pick(rng)], N = n_choices[pick(rng)];
            Mat a = rand_mat(rng, M, K, -20, 19);
            Mat w = rand_mat(rng, K, N, -20, 19);
            Vec b = rand_vec(rng, N, -50, 49);
            Mat expected = golden(a, w, b), got;
            if (!(tb.matmul_tiled(a, w, b, got) && eq(got, expected))) {
                if (fails++ == 0) {
                    printf("       [tiled %d] M=%d K=%d N=%d\n", i, M, K, N);
                    dump("got", got); dump("expected", expected);
                }
            }
        }
        char buf[96];
        snprintf(buf, sizeof buf, "tiled stress: %d/%d randomized multi-tile matmuls matched golden", n - fails, n);
        report(fails == 0, buf);
    }

    // 8) STREAM_RUN frame boundaries: K_TILES at 1 / 3 / max / max+1 / max+9
    //    (multi-frame K-run chaining -- the case MNIST's K=144 layer needs)
    {
        std::mt19937 rng(3);
        int kts[] = {1, 3, MAX_STREAM_TILES, MAX_STREAM_TILES + 1, MAX_STREAM_TILES + 9};
        int fails = 0;
        for (int kt : kts) {
            Mat a = rand_mat(rng, MTILE, ROWS * kt, -20, 19);
            Mat w = rand_mat(rng, ROWS * kt, COLS, -20, 19);
            Vec b = rand_vec(rng, COLS, -50, 49);
            Mat expected = golden(a, w, b), got;
            if (!(tb.matmul_tiled(a, w, b, got) && eq(got, expected))) {
                printf("       [stream K_TILES=%d] mismatch\n", kt);
                fails++;
            }
        }
        char buf[96];
        snprintf(buf, sizeof buf,
                 "stream boundaries: %d/5 K-runs (K_TILES 1,3,%d,%d,%d) matched golden",
                 5 - fails, MAX_STREAM_TILES, MAX_STREAM_TILES + 1, MAX_STREAM_TILES + 9);
        report(fails == 0, buf);
    }

    printf("=== %s: %d passed, %d failed (%llu cycles simulated) ===\n",
           g_fail == 0 ? "ALL TESTS PASSED" : "FAILURES", g_pass, g_fail,
           (unsigned long long)tb.cycles);
    return g_fail == 0 ? 0 : 1;
}
