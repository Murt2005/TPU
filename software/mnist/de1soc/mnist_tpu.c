/* MNIST end to end on the DE1-SoC's ARM: raw 28x28 pixels -> downsample ->
 * quantize -> the instruction-stream TPU over the lightweight bridge -> argmax.
 *
 *   mnist_tpu bench <model.bin> <testset.bin> [count]
 *       every test image at m=1 and m=8: accuracy, exact agreement with the
 *       reference model, preprocessing agreement with the host, wall time
 *   mnist_tpu serve <model.bin>
 *       for the drawing GUI over the console: 'I' + 784 pixels -> 'R' + digit +
 *       10 int32 scores + u32 microseconds, digit shown on HEX0; 'C' blanks the
 *       display -> 'K'; 'Q' quits
 *
 * built with -DSIM, register accesses go to a Verilator tb_isa binary (TB_ISA)
 * over its pipe protocol instead of /dev/mem, so the whole flow runs on the Mac */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

enum { INSN_LO, INSN_HI, DATA, OUT, STATUS, LEVELS, CTRL, ERR_SEQ, PERF_CYCLES };
enum { CTRL_RESET = 1, CTRL_CLEAR_DONE = 2, CTRL_CLEAR_PERF = 4 };

#define HEX_BLANK 16u
#define HEX_DASH  17u

/* -- register access ------------------------------------------------------ */
#ifdef SIM
#include <signal.h>
#include <sys/wait.h>
static FILE *to_tb, *from_tb;

static void reg_open(void) {
    const char *tb = getenv("TB_ISA");
    int in[2], out[2];
    if (!tb || pipe(in) || pipe(out)) { fprintf(stderr, "set TB_ISA to a tb_isa binary\n"); exit(1); }
    if (fork() == 0) {
        dup2(in[0], 0); dup2(out[1], 1);
        close(in[1]); close(out[0]);
        execl(tb, tb, (char *)0);
        _exit(127);
    }
    close(in[0]); close(out[1]);
    to_tb = fdopen(in[1], "wb");
    from_tb = fdopen(out[0], "rb");
    uint32_t hdr[5];
    if (fread(hdr, 4, 5, from_tb) != 5) { fprintf(stderr, "tb_isa didn't start\n"); exit(1); }
}
static void reg_wr(int reg, uint32_t v) {
    uint8_t b[6] = {'W', (uint8_t)reg, (uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)};
    fwrite(b, 1, 6, to_tb);
}
static uint32_t reg_rd(int reg) {
    uint8_t b[2] = {'R', (uint8_t)reg};
    uint32_t v;
    fwrite(b, 1, 2, to_tb);
    fflush(to_tb);
    if (fread(&v, 4, 1, from_tb) != 1) { fprintf(stderr, "tb_isa exited\n"); exit(1); }
    return v;
}
static void hex_set(uint32_t code) { (void)code; }
static void reg_close(void) { fputc('Q', to_tb); fflush(to_tb); wait(0); }
#else
#include <fcntl.h>
#include <sys/mman.h>
#define LWH2F_BASE 0xFF200000u
#define TPU_OFF    0x0u
#define HEX_OFF    0x10100u
static volatile uint32_t *lw;

static void reg_open(void) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); exit(1); }
    lw = mmap(0, 0x11000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, LWH2F_BASE);
    if (lw == MAP_FAILED) { perror("mmap"); exit(1); }
}
static void reg_wr(int reg, uint32_t v) { lw[TPU_OFF / 4 + reg] = v; }
static uint32_t reg_rd(int reg) { return lw[TPU_OFF / 4 + reg]; }
static void hex_set(uint32_t code) { lw[HEX_OFF / 4] = code; }
static void reg_close(void) {}
#endif

/* -- the compiled model --------------------------------------------------- */
#define MAX_M 8
typedef struct {
    uint32_t n, k_in, kt, nb_out, n_out, side;
    float in_scale;
    uint32_t edges[33];
    uint32_t n_load, n_load_data;
    uint64_t *load;
    uint32_t *load_data;
    uint32_t n_infer[MAX_M + 1];
    uint64_t *infer[MAX_M + 1];
} model_t;

static void *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END);
    *len = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    void *p = malloc(*len);
    if (fread(p, 1, *len, f) != *len) { perror(path); exit(1); }
    fclose(f);
    return p;
}

static uint32_t u32(const uint8_t **p) { uint32_t v; memcpy(&v, *p, 4); *p += 4; return v; }

static void model_load(model_t *md, const char *path) {
    size_t len;
    const uint8_t *p = slurp(path, &len);
    if (memcmp(p, "TPUM", 4)) { fprintf(stderr, "%s: not a model.bin\n", path); exit(1); }
    p += 4;
    u32(&p);                                                   /* version */
    md->n = u32(&p); md->k_in = u32(&p); md->kt = u32(&p);
    md->nb_out = u32(&p); md->n_out = u32(&p); md->side = u32(&p);
    uint32_t n_ms = u32(&p);
    u32(&p);
    memcpy(&md->in_scale, p, 4); p += 4;
    for (uint32_t i = 0; i <= md->side; i++) md->edges[i] = u32(&p);
    md->n_load = u32(&p); md->n_load_data = u32(&p);
    md->load = (uint64_t *)p; p += 8 * md->n_load;
    md->load_data = (uint32_t *)p; p += 4 * md->n_load_data;
    for (uint32_t k = 0; k < n_ms; k++) {
        uint32_t m = u32(&p), ni = u32(&p);
        md->n_infer[m] = ni;
        md->infer[m] = (uint64_t *)p;
        p += 8 * ni;
    }
}

/* -- the TPU -------------------------------------------------------------- */
static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

/* push a program ending in SIGNAL plus its data, wait for DONE, read nout words */
static void tpu_run(const uint64_t *insn, uint32_t ni, const uint32_t *data, uint32_t nd,
                    uint32_t *out, uint32_t nout) {
    reg_wr(CTRL, CTRL_CLEAR_DONE);
    for (uint32_t i = 0; i < ni; i++) {
        reg_wr(INSN_LO, (uint32_t)insn[i]);
        reg_wr(INSN_HI, (uint32_t)(insn[i] >> 32));
    }
    for (uint32_t i = 0; i < nd; i++) reg_wr(DATA, data[i]);
    for (;;) {
        uint32_t st = reg_rd(STATUS);
        if (st & 2) {
            fprintf(stderr, "TPU error %u at instruction %u\n", (st >> 8) & 0xFF, reg_rd(ERR_SEQ));
            exit(2);
        }
        if (st & 1) break;
    }
    for (uint32_t i = 0; i < nout; i++) out[i] = reg_rd(OUT);
}

/* numpy's float32 math exactly: pixels / 255, block mean summed row-major,
 * / in_scale, round half to even, clip */
static void preprocess(const model_t *md, const uint8_t *px, int8_t *xq) {
    uint32_t s = md->side;
    for (uint32_t i = 0; i < s; i++)
        for (uint32_t j = 0; j < s; j++) {
            float sum = 0.0f;
            int cnt = 0, first = 1;
            for (uint32_t r = md->edges[i]; r < md->edges[i + 1]; r++)
                for (uint32_t c = md->edges[j]; c < md->edges[j + 1]; c++) {
                    float v = (float)px[r * 28 + c] / 255.0f;
                    sum = first ? v : sum + v;
                    first = 0;
                    cnt++;
                }
            float q = nearbyintf((sum / (float)cnt) / md->in_scale);
            xq[i * s + j] = (int8_t)(q > 127.0f ? 127 : q < -128.0f ? -128 : q);
        }
}

/* m quantized inputs -> UB data words (K-chunk-major: chunk k of row i at k*m + i) */
static uint32_t pack_ub(const model_t *md, const int8_t *xq, uint32_t m, uint32_t *words) {
    uint32_t w = 0, n = md->n;
    for (uint32_t k = 0; k < md->kt; k++)
        for (uint32_t i = 0; i < m; i++)
            for (uint32_t c = 0; c < n; c += 4) {
                uint32_t v = 0;
                for (uint32_t b = 0; b < 4; b++) {
                    uint32_t col = k * n + c + b;
                    int8_t x = col < md->k_in ? xq[i * md->k_in + col] : 0;
                    v |= (uint32_t)(uint8_t)x << (8 * b);
                }
                words[w++] = v;
            }
    return w;
}

/* m images -> predictions (and the scores of row 0) */
static void infer(const model_t *md, const int8_t *xq, uint32_t m, uint8_t *pred, int32_t *scores0) {
    static uint32_t data[4096], out[1024];
    uint32_t nd = pack_ub(md, xq, m, data);
    uint32_t nout = md->nb_out * m * md->n;
    tpu_run(md->infer[m], md->n_infer[m], data, nd, out, nout);
    for (uint32_t i = 0; i < m; i++) {
        int32_t best = 0;
        for (uint32_t j = 0; j < md->n_out; j++) {
            uint32_t b = j / md->n, c = j % md->n;
            int32_t v = (int32_t)out[(b * m + i) * md->n + c];
            if (i == 0 && scores0) scores0[j] = v;
            if (j == 0 || v > best) { best = v; pred[i] = (uint8_t)j; }
        }
    }
}

static void tpu_init(const model_t *md) {
    reg_wr(CTRL, CTRL_RESET | CTRL_CLEAR_PERF);
    tpu_run(md->load, md->n_load, md->load_data, md->n_load_data, 0, 0);
}

/* -- modes ----------------------------------------------------------------- */
static int bench(const model_t *md, const char *path, uint32_t limit) {
    size_t len;
    const uint8_t *p = slurp(path, &len);
    if (memcmp(p, "TPUT", 4)) { fprintf(stderr, "%s: not a testset.bin\n", path); return 1; }
    p += 8;
    uint32_t count = u32(&p), kin = u32(&p);
    if (limit && limit < count) count = limit;
    const uint32_t rec = 784 + 3 + kin;
    int8_t *xq = malloc(count * kin);
    uint8_t *pred = malloc(count);

    double t0 = now();
    uint32_t pre_bad = 0;
    for (uint32_t k = 0; k < count; k++) {
        const uint8_t *r = p + (size_t)k * rec;
        preprocess(md, r, xq + k * kin);
        pre_bad += memcmp(xq + k * kin, r + 787, kin) != 0;
    }
    double t_pre = (now() - t0) / count;
    printf("preprocess: %u images, %u differ from the host's quantized input, %.1f us/image\n",
           count, pre_bad, t_pre * 1e6);

    static const uint32_t ms[2] = {1, 8};
    for (int v = 0; v < 2; v++) {
        uint32_t m = ms[v];
        tpu_init(md);
        reg_wr(CTRL, CTRL_CLEAR_PERF);
        double t1 = now();
        for (uint32_t k = 0; k < count; k += m) {
            uint32_t mm = count - k < m ? count - k : m;
            static int8_t batch[MAX_M * 1024];
            memset(batch, 0, m * kin);
            memcpy(batch, xq + k * kin, mm * kin);
            uint8_t pb[MAX_M];
            infer(md, batch, m, pb, 0);
            memcpy(pred + k, pb, mm);
        }
        double t_run = (now() - t1) / count;
        uint32_t cycles = reg_rd(PERF_CYCLES);
        uint32_t correct = 0, ref_ok = 0, host_ok = 0;
        for (uint32_t k = 0; k < count; k++) {
            const uint8_t *r = p + (size_t)k * rec + 784;
            correct += pred[k] == r[0];
            ref_ok += pred[k] == r[1];
            host_ok += pred[k] == r[2];
        }
        printf("m=%u: accuracy %.2f%% (%u/%u), == reference model %u/%u, == host path %u/%u\n",
               m, 100.0 * correct / count, correct, count, ref_ok, count, host_ok, count);
        printf("m=%u: %.1f us/image on the TPU path, %.1f us/image end to end with preprocessing "
               "(%.0f images/s); %u fabric cycles at 50 MHz = %.1f us/image\n",
               m, t_run * 1e6, (t_run + t_pre) * 1e6, 1.0 / (t_run + t_pre), cycles,
               cycles / 50.0 / count);
    }
    return 0;
}

static int get(void *b, size_t n) {
    uint8_t *q = b;
    while (n) {
        ssize_t k = read(0, q, n);
        if (k <= 0) return 0;
        q += k;
        n -= (size_t)k;
    }
    return 1;
}

static void put(const void *b, size_t n) {
    const uint8_t *q = b;
    while (n) {
        ssize_t k = write(1, q, n);
        if (k <= 0) exit(3);
        q += k;
        n -= (size_t)k;
    }
}

static uint32_t hex_digit(uint32_t d) {
    uint32_t code = 0;
    for (int i = 5; i >= 1; i--) code = code << 5 | HEX_BLANK;
    return code << 5 | d;
}

static uint32_t hex_dashes(void) {
    uint32_t code = 0;
    for (int i = 0; i < 6; i++) code = code << 5 | HEX_DASH;
    return code;
}

static int serve(const model_t *md) {
    struct termios saved, raw;
    int tty = isatty(0) && tcgetattr(0, &saved) == 0;
    if (tty) { raw = saved; cfmakeraw(&raw); tcsetattr(0, TCSANOW, &raw); }
    tpu_init(md);
    hex_set(hex_dashes());
    put("S", 1);                                   /* ready */
    static uint8_t px[784];
    for (;;) {
        uint8_t cmd;
        if (!get(&cmd, 1) || cmd == 'Q') break;
        if (cmd == 'C') { hex_set(hex_dashes()); put("K", 1); continue; }
        if (cmd != 'I' || !get(px, sizeof px)) break;
        double t0 = now();
        int8_t xq[MAX_M * 1024] = {0};
        uint8_t pred[MAX_M];
        int32_t scores[16];
        preprocess(md, px, xq);
        infer(md, xq, 1, pred, scores);
        uint32_t us = (uint32_t)((now() - t0) * 1e6);
        hex_set(hex_digit(pred[0]));
        put("R", 1);
        put(pred, 1);
        put(scores, 4 * md->n_out);
        put(&us, 4);
    }
    if (tty) tcsetattr(0, TCSANOW, &saved);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s bench <model.bin> <testset.bin> [count] | serve <model.bin>\n", argv[0]);
        return 1;
    }
    model_t md = {0};
    model_load(&md, argv[2]);
    reg_open();
    int rc;
    if (!strcmp(argv[1], "bench") && argc >= 4)
        rc = bench(&md, argv[3], argc > 4 ? (uint32_t)atoi(argv[4]) : 0);
    else if (!strcmp(argv[1], "serve"))
        rc = serve(&md);
    else
        rc = 1;
    reg_close();
    return rc;
}
