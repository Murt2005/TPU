// full-chip bench: drives tpu_top through its real UART or SPI pins (or tpu_core
// directly with -DTB_DIRECT), replaying hw_regression.py's cases plus a framing-error
// case only simulation can do. shape comes from -DTB_ROWS/-DTB_COLS/-DTB_MTILE

#include <cstdint>
#include <cstdio>
#include <memory>
#include <random>
#include <string>
#include <vector>

#if defined(TB_DIRECT)
// direct mode: no PHY and no power-on reset, reset is a plain input
#include "Vtpu_core.h"
using Dut = Vtpu_core;
#else
#include "Vtpu_top.h"
using Dut = Vtpu_top;
#endif
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
#ifndef TB_PSUM_WIDTH
#define TB_PSUM_WIDTH 16
#endif

// must match the -GCLK_FREQ/-GBAUD_RATE the model was verilated with
static constexpr int TICKS_PER_BIT = 12;

static constexpr int ROWS   = TB_ROWS;
static constexpr int COLS   = TB_COLS;
static constexpr int MTILE  = TB_MTILE;
static constexpr int PSUM_W     = TB_PSUM_WIDTH;
static constexpr int PSUM_BYTES = PSUM_W / 8;

static constexpr int W_BYTES      = ROWS * COLS;
static constexpr int A_BYTES      = MTILE * ROWS;
static constexpr int RESULT_BYTES = PSUM_BYTES * MTILE * COLS;
static constexpr int TILE_BYTES   = W_BYTES + A_BYTES;
static constexpr int MAX_STREAM_TILES = (255 - 2) / TILE_BYTES;

static constexpr uint8_t CMD_LOAD_WEIGHTS = 0x01;
static constexpr uint8_t CMD_LOAD_BIAS    = 0x02;
static constexpr uint8_t CMD_LOAD_ACT     = 0x03;
static constexpr uint8_t CMD_RUN          = 0x04;
static constexpr uint8_t CMD_RESET        = 0x05;
static constexpr uint8_t CMD_RUN_TILE     = 0x06;
static constexpr uint8_t CMD_STREAM_RUN   = 0x07;

static constexpr uint8_t FLAG_TILE_FIRST = 0x01;
static constexpr uint8_t FLAG_TILE_LAST  = 0x02;
static constexpr uint8_t FLAG_ACT_BYPASS = 0x04;

static inline uint8_t mk_flags(bool first, bool last, bool bypass) {
    return (uint8_t)((first ? FLAG_TILE_FIRST : 0) |
                     (last ? FLAG_TILE_LAST : 0) |
                     (bypass ? FLAG_ACT_BYPASS : 0));
}

static constexpr int STATUS_OK  = 0xAA;
static constexpr int STATUS_ERR = 0xFF;

using Mat  = std::vector<std::vector<int>>;
using Vec  = std::vector<int>;
using Bytes = std::vector<uint8_t>;

// reference numerics, a C++ copy of host/tpu/golden.py
static long long wrap_psum(long long s) {
    if (PSUM_W >= 64) return s;
    const unsigned long long span = 1ULL << PSUM_W;
    unsigned long long u = (unsigned long long)s & (span - 1);
    return (u & (span >> 1)) ? (long long)u - (long long)span : (long long)u;
}

// only to make the wide-PSUM test's message concrete
static long long wrap_psum_16(long long s) {
    return (long long)(int16_t)(uint16_t)(s & 0xFFFF);
}

// relu=false models ACT_BYPASS
static Mat golden(const Mat& a, const Mat& w, const Vec& bias, bool relu = true) {
    size_t m = a.size(), k = w.size(), n = w[0].size();
    Mat out(m, std::vector<int>(n));
    for (size_t i = 0; i < m; i++) {
        for (size_t j = 0; j < n; j++) {
            long long s = bias[j];
            for (size_t x = 0; x < k; x++) s += (long long)a[i][x] * w[x][j];
            long long wrapped = wrap_psum(s);
            out[i][j] = (int)(relu && wrapped < 0 ? 0 : wrapped);
        }
    }
    return out;
}

struct Tb {
    std::unique_ptr<Dut> dut{new Dut};
    uint64_t cycles = 0;
#ifdef TB_DIRECT
    Bytes tx_seen;
#endif

    Tb() {
        dut->clk = 0;
#ifdef TB_DIRECT
        dut->reset    = 1;
        dut->rx_data  = 0;
        dut->rx_valid = 0;
        dut->rx_error = 0;
        // no PHY, so tx is never busy
        dut->tx_busy  = 0;
        dut->eval();
        cycle(8);
        dut->reset = 0;
        cycle(4);
#else
        dut->reset_n = 1;
        dut->rx_pin = 1;  // UART idle high
#ifdef TB_SPI
        dut->spi_sck = 0;
        dut->spi_csn = 1;
        dut->spi_mosi = 0;
#endif
        dut->eval();
        // the power-on reset holds for 256 cycles
        cycle(300);
#endif
    }

    void cycle(int n = 1) {
        for (int i = 0; i < n; i++) {
            dut->clk = 1; dut->eval();
#ifdef TB_DIRECT
            // tx_valid is a one-cycle pulse, so sampling after the posedge sees each byte once
            if (dut->tx_valid) tx_seen.push_back((uint8_t)dut->tx_data);
#endif
            dut->clk = 0; dut->eval();
            cycles++;
        }
    }

#if defined(TB_DIRECT)
    // the sequencer ignores RX for one pipeline pass between STREAM_RUN tiles; real
    // links hide that behind their byte cadence, here the gap is explicit. a sweep at
    // 8x8/M_TILE=4 failed at 40 cycles and passed at 48 (47 predicted), so 2x is margin
    static constexpr int PASS_CYCLES = 2 * MTILE + 2 * ROWS + COLS + 16;
    static constexpr int STREAM_TILE_GAP = 2 * PASS_CYCLES;

    // the TX FSM needs a few cycles to reach S_IDLE; a CMD byte arriving sooner is
    // dropped and desyncs the frame
    static constexpr int CMD_SETTLE_GAP = 32;

    void send_byte(uint8_t v, bool good_stop = true) {
        if (!good_stop) {
            // a PHY framing error: rx_error rises and the bad byte never pulses rx_valid
            dut->rx_error = 1; cycle(); dut->rx_error = 0; cycle();
            return;
        }
        dut->rx_data = v; dut->rx_valid = 1; cycle();
        dut->rx_valid = 0; cycle();
    }

    int recv_byte(uint64_t timeout_cycles = 500000) {
        while (tx_seen.empty()) {
            cycle();
            if (--timeout_cycles == 0) return -1;
        }
        int v = tx_seen.front();
        tx_seen.erase(tx_seen.begin());
        return v;
    }

    int send_cmd(uint8_t cmd, const Bytes& payload, Bytes& resp) {
        // settle before the CMD byte: the raw send_byte/recv_byte tests need it too
        cycle(CMD_SETTLE_GAP);
        send_byte(cmd);
        send_byte((uint8_t)payload.size());
        for (size_t i = 0; i < payload.size(); i++) {
            send_byte(payload[i]);
            if (cmd == CMD_STREAM_RUN && i >= 2 && ((i - 1) % TILE_BYTES) == 0)
                cycle(STREAM_TILE_GAP);
        }
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
        cycle(CMD_SETTLE_GAP);
        return status;
    }
#elif !defined(TB_SPI)
    // UART master
    void send_bit(int b) { dut->rx_pin = b; cycle(TICKS_PER_BIT); }

    void send_byte(uint8_t v, bool good_stop = true) {
        send_bit(0);                                    // start
        for (int i = 0; i < 8; i++) send_bit((v >> i) & 1);  // LSB first
        send_bit(good_stop ? 1 : 0);                    // stop
        dut->rx_pin = 1;
        cycle(2);                                       // brief inter-byte idle
    }

    // <0 on timeout
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

    // returns the status byte, or <0 on timeout
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
#else
    // SPI mode-0 master: write SCK = CLK/6, read polls at CLK/10 (spi_slave caps reads at CLK/8)
    static constexpr int WR_HALF = 3;
    static constexpr int RD_HALF = 5;

    void cs(bool active) {
        dut->spi_csn = active ? 0 : 1;
        cycle(8);                    // CS lead/lag (module needs >= 5 clk)
    }

    uint8_t spi_xfer(uint8_t w, int half) {
        uint8_t r = 0;
        for (int i = 7; i >= 0; i--) {
            dut->spi_mosi = (w >> i) & 1;
            cycle(half);             // low phase: slave's MISO bit settles
            r |= (uint8_t)(dut->spi_miso & 1) << i;  // master samples at rising
            dut->spi_sck = 1;
            cycle(half);
            dut->spi_sck = 0;
        }
        return r;
    }

    int send_cmd(uint8_t cmd, const Bytes& payload, Bytes& resp) {
        cs(true);                    // command frame: one CS burst
        spi_xfer(cmd, WR_HALF);
        spi_xfer((uint8_t)payload.size(), WR_HALF);
        for (uint8_t b : payload) spi_xfer(b, WR_HALF);
        cs(false);

        cs(true);                    // response: poll 0xFF filler until STATUS
        int status = -1;
        for (int polls = 0; polls < 20000; polls++) {
            uint8_t b = spi_xfer(0xFF, RD_HALF);
            if (b != 0x00) { status = b; break; }
        }
        if (status < 0) { cs(false); return -1; }
        int len = spi_xfer(0xFF, RD_HALF);
        resp.clear();
        for (int i = 0; i < len; i++) resp.push_back(spi_xfer(0xFF, RD_HALF));
        cs(false);
        return status;
    }
#endif

    // protocol commands, mirroring the host driver

    bool load_weights(const Mat& w) {   // (ROWS x COLS), bottom row first on the wire
        Bytes p;
        for (int r = ROWS - 1; r >= 0; r--)
            for (int c = 0; c < COLS; c++) p.push_back((uint8_t)(int8_t)w[r][c]);
        Bytes resp;
        return send_cmd(CMD_LOAD_WEIGHTS, p, resp) == STATUS_OK;
    }

    bool load_bias(const Vec& b) {      // COLS signed LE, PSUM_BYTES each
        Bytes p;
        for (int c = 0; c < COLS; c++) {
            uint64_t v = (uint64_t)(int64_t)b[c];
            for (int i = 0; i < PSUM_BYTES; i++) p.push_back((uint8_t)(v >> (8 * i)));
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
                int idx = PSUM_BYTES * (m * COLS + c);
                unsigned long long v = 0;
                for (int i = 0; i < PSUM_BYTES; i++)
                    v |= (unsigned long long)resp[idx + i] << (8 * i);
                out[m][c] = (int)wrap_psum((long long)v);
            }
        return out;
    }

    bool run(Mat& result, bool first = true, bool last = true,
             bool bypass = false) {
        Bytes p;
        if (!(first && last && !bypass)) p.push_back(mk_flags(first, last, bypass));
        Bytes resp;
        if (send_cmd(CMD_RUN, p, resp) != STATUS_OK) return false;
        if (!last) return true;
        if ((int)resp.size() != RESULT_BYTES) return false;
        result = parse_result(resp);
        return true;
    }

    bool run_tile(const Mat& w, const Mat& a, Mat& result,
                  bool first = true, bool last = true, bool bypass = false) {
        Bytes p{mk_flags(first, last, bypass)};
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

    bool stream_run(const std::vector<Mat>& w_tiles, const std::vector<Mat>& a_tiles,
                    Mat& result, bool first, bool last, bool bypass = false) {
        Bytes p{mk_flags(first, last, bypass), (uint8_t)w_tiles.size()};
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

    // port of the host's matmul_tiled()
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

// fixed seeds, so failures reproduce
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

// hw_regression.py's seven case patterns, at this build's shape
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

#ifdef TB_DIRECT
// bridge: a transport for tpu_host.py --link sim instead of a test. NOP gets
// no response and the inter-tile and settle gaps match send_cmd()
static int bridge_main(Tb& tb) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    for (;;) {
        int c = getchar();
        if (c == EOF) return 0;
        uint8_t cmd = (uint8_t)c;
        tb.cycle(Tb::CMD_SETTLE_GAP);
        if (cmd == 0xFF) { tb.send_byte(cmd); continue; }   // NOP: no response

        int l = getchar();
        if (l == EOF) return 0;
        uint8_t len = (uint8_t)l;
        tb.send_byte(cmd);
        tb.send_byte(len);
        for (int i = 0; i < len; i++) {
            int b = getchar();
            if (b == EOF) return 0;
            tb.send_byte((uint8_t)b);
            if (cmd == CMD_STREAM_RUN && i >= 2 && ((i - 1) % TILE_BYTES) == 0)
                tb.cycle(Tb::STREAM_TILE_GAP);
        }

        int status = tb.recv_byte();
        if (status < 0) return 1;                 // DUT never answered
        int rlen = tb.recv_byte();
        if (rlen < 0) return 1;
        putchar(status);
        putchar(rlen);
        for (int i = 0; i < rlen; i++) {
            int b = tb.recv_byte();
            if (b < 0) return 1;
            putchar(b);
        }
        fflush(stdout);
        tb.cycle(Tb::CMD_SETTLE_GAP);
    }
}
#endif

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
#ifdef TB_DIRECT
    for (int i = 1; i < argc; i++) {
        if (std::string(argv[i]) == "--bridge") {
            Tb bridge_tb;
            return bridge_main(bridge_tb);
        }
    }
#endif
#if defined(TB_DIRECT)
    printf("=== tb_tpu_top: %dx%d array, M_TILE=%d, PSUM=%d (direct injection into tpu_core) ===\n",
           ROWS, COLS, MTILE, PSUM_W);
#elif defined(TB_SPI)
    printf("=== tb_tpu_top: %dx%d array, M_TILE=%d (SPI PHY) ===\n",
           ROWS, COLS, MTILE);
#else
    printf("=== tb_tpu_top: %dx%d array, M_TILE=%d (UART PHY, TICKS_PER_BIT=%d) ===\n",
           ROWS, COLS, MTILE, TICKS_PER_BIT);
#endif
    Tb tb;

    // 1) fixed pattern cases
    auto cases = build_cases();
    for (auto& [name, a, w, b] : cases) check_case(tb, name, a, w, b);

    // 2) reset roundtrip
    {
        bool ok = tb.reset_cmd();
        auto& [name, a, w, b] = cases[0];
        Mat expected = golden(a, w, b), got;
        ok = ok && tb.matmul(a, w, b, got) && eq(got, expected);
        report(ok, "T3b post-reset compute");
    }

    // 3) unknown CMD (not 0xFF, which is the NOP filler)
    {
        Bytes resp;
        int status = tb.send_cmd(0xEE, {}, resp);
        report(status == STATUS_ERR && resp.empty(), "T4 unknown CMD 0xEE -> STATUS_ERR");
    }

#ifndef TB_SPI
    // 3b) NOP filler is ignored; under TB_SPI every poll already covers this
    {
        tb.send_byte(0xFF);
        tb.send_byte(0xFF);
        tb.send_byte(0xFF);
        bool ok = (tb.recv_byte(3000) == -1);   // no response expected
        auto& [name, a, w, b] = cases[0];
        Mat expected = golden(a, w, b), got;
        ok = ok && tb.matmul(a, w, b, got) && eq(got, expected);
        report(ok, "T4c NOP 0xFF filler ignored + next command parses");
    }

    // 4) framing error and recovery, simulation-only (no framing on SPI)
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
#endif

    // 5) randomized single-tile stress
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

    // 6) RUN_TILE equivalence with the legacy path
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

    // 7) matmul_tiled stress, including non-multiples of the tile
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

    // 8) STREAM_RUN frame boundaries
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

    // 9) ACT_BYPASS: a strongly negative bias must survive unclamped
    {
        std::mt19937 rng(11);
        int fails = 0, negatives = 0;
        for (int i = 0; i < 10; i++) {
            Mat a = rand_mat(rng, MTILE, ROWS, 1, 20);
            Mat w = rand_mat(rng, ROWS, COLS, 1, 20);
            Vec b = rand_vec(rng, COLS, -8000, -4000);

            Mat clamped, raw;
            bool ok = tb.load_activations(a) && tb.load_weights(w) &&
                      tb.load_bias(b) && tb.run(clamped, true, true, false) &&
                      tb.run(raw, true, true, true);
            if (!ok) { fails++; continue; }
            if (!eq(clamped, golden(a, w, b, true)))  fails++;
            if (!eq(raw, golden(a, w, b, false)))     fails++;
            for (auto& row : raw) for (int v : row) if (v < 0) negatives++;
        }
        // the check is vacuous unless bypass actually produced negatives
        char buf[128];
        snprintf(buf, sizeof buf,
                 "ACT_BYPASS: 10 pairs clamped/raw matched golden (%d negative values survived)",
                 negatives);
        report(fails == 0 && negatives > 0, buf);
    }

    // 10) ACT_BYPASS through RUN_TILE and STREAM_RUN too
    {
        std::mt19937 rng(12);
        int fails = 0;
        for (int i = 0; i < 5; i++) {
            Mat a = rand_mat(rng, MTILE, ROWS, 1, 20);
            Mat w = rand_mat(rng, ROWS, COLS, 1, 20);
            Vec b = rand_vec(rng, COLS, -8000, -4000);
            Mat expected = golden(a, w, b, false), got;
            if (!(tb.load_bias(b) && tb.run_tile(w, a, got, true, true, true) &&
                  eq(got, expected))) fails++;

            std::vector<Mat> wt{w}, at{a};
            Mat got2;
            if (!(tb.load_bias(b) &&
                  tb.stream_run(wt, at, got2, true, true, true) &&
                  eq(got2, expected))) fails++;
        }
        report(fails == 0, "ACT_BYPASS via RUN_TILE and STREAM_RUN: 5/5 each matched golden");
    }

    // 11) wide PSUM: ROWS*127*127 exceeds int16 from ROWS >= 3, and must come back intact
    {
        Mat a(MTILE, std::vector<int>(ROWS, 127));
        Mat w(ROWS, std::vector<int>(COLS, 127));
        Vec b(COLS, 0);
        long long exact = (long long)ROWS * 127 * 127;
        Mat got;
        bool ok = tb.matmul(a, w, b, got) && eq(got, golden(a, w, b));
        char buf[160];
        if (PSUM_W > 16 && exact > 32767) {
            ok = ok && got[0][0] == (int)exact;
            snprintf(buf, sizeof buf,
                     "wide PSUM: %lld returned intact (int16 would wrap it to %lld)",
                     exact, wrap_psum_16(exact));
        } else {
            snprintf(buf, sizeof buf,
                     "PSUM_W=%d: ROWS*127*127=%lld matches golden", PSUM_W, exact);
        }
        report(ok, buf);
        if (!ok) { dump("got", got); dump("expected", golden(a, w, b)); }
    }

    printf("=== %s: %d passed, %d failed (%llu cycles simulated) ===\n",
           g_fail == 0 ? "ALL TESTS PASSED" : "FAILURES", g_pass, g_fail,
           (unsigned long long)tb.cycles);
    return g_fail == 0 ? 0 : 1;
}
