/* the cores a linear layer runs on. core_program builds the same program as
 * core_runtime.py, word for word (check.py-style test: test_runtime.py):
 *     RD_DDR_UB (up to 4,096 entries each), SET_WBASE, WAIT MM on LD,
 *     per chunk of output blocks: [WAIT MM on ACT,] MATMUL wsrc=1, SET_OBASE,
 *         WAIT ACT on MM, ACTIVATE dst=DDR (identity, no bias, int32),
 *     SIGNAL
 * DDR3 from `base`: the weight image, then 1 MB of input, then the output */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "qwen.h"

#define N_ARRAY        8
#define TILE_BYTES     (N_ARRAY * N_ARRAY)
#define ACC_ROWS       1024
#define UB_ENTRIES     16384
#define RD_DDR_UB_MAX  4096
#define N_BLOCKS_MAX   1024
#define LD 0
#define WT 1
#define MM 2
#define ACT 3

/* instruction fields, as host/tpu/isa.py */
static uint64_t field(uint64_t v, int hi, int lo) { return (v & ((1ull << (hi - lo + 1)) - 1)) << lo; }
#define OP(code) ((uint64_t)(code) << 58)
static uint64_t rd_ddr_ub(uint32_t ub, uint32_t n, uint32_t a) {
    return OP(0x05) | field(ub, 57, 44) | field(n - 1, 43, 32) | field(a, 31, 0);
}
static uint64_t set_wbase(uint32_t w) { return OP(0x06) | field(w, 31, 0); }
static uint64_t set_obase(uint32_t o) { return OP(0x07) | field(o, 31, 0); }
static uint64_t matmul_wsrc1(uint32_t m, uint32_t kt, uint32_t nb) {
    return OP(0x10) | field(1, 56, 56) | field(m - 1, 55, 48) | field(kt - 1, 47, 36) | field(nb - 1, 35, 26);
}
static uint64_t activate_ddr(uint32_t nb, uint32_t m) {   /* identity, int32, no bias, ACC row 0 */
    return OP(0x18) | field(2, 54, 53) | field(nb - 1, 51, 42) | field(m - 1, 41, 34);
}
static uint64_t wait_on(int target, int engine) { return OP(0x20) | field(target, 57, 56) | field(1u << engine, 51, 48); }
static uint64_t signal_tag(uint32_t tag) { return OP(0x21) | field(tag, 15, 0); }

static uint32_t inputs_at(uint32_t base, uint64_t image_bytes) {
    return (uint32_t)((base + image_bytes + (1u << 20) - 1) & ~(uint64_t)((1u << 20) - 1));
}

int core_program(const matrix *mx, int m, uint32_t first_block, uint32_t block_count, uint32_t base,
                 uint64_t image_bytes, uint64_t *w, int max, int *chunks, int *chunk_blocks, uint32_t *chunk_obase) {
    uint32_t inputs = inputs_at(base, image_bytes), outputs = inputs + (1u << 20);
    uint32_t entries = mx->k_tiles * (uint32_t)m;
    int count = 0;
    if (entries > UB_ENTRIES) return -1;
    for (uint32_t first = 0; first < entries; first += RD_DDR_UB_MAX) {
        uint32_t n = entries - first < RD_DDR_UB_MAX ? entries - first : RD_DDR_UB_MAX;
        w[count++] = rd_ddr_ub(first, n, inputs + first * N_ARRAY);
    }
    w[count++] = set_wbase(base / TILE_BYTES + mx->tile + first_block * mx->k_tiles);
    w[count++] = wait_on(MM, LD);
    uint32_t per = ACC_ROWS / (uint32_t)m < N_BLOCKS_MAX ? ACC_ROWS / (uint32_t)m : N_BLOCKS_MAX;
    uint32_t done = 0, obase = outputs;
    *chunks = 0;
    while (done < block_count) {
        uint32_t nb = block_count - done < per ? block_count - done : per;
        if (*chunks) w[count++] = wait_on(MM, ACT);
        w[count++] = matmul_wsrc1((uint32_t)m, mx->k_tiles, nb);
        w[count++] = set_obase(obase);
        w[count++] = wait_on(ACT, MM);
        w[count++] = activate_ddr(nb, (uint32_t)m);
        chunk_blocks[*chunks] = (int)nb;
        chunk_obase[*chunks] = obase;
        (*chunks)++;
        obase += nb * (uint32_t)m * N_ARRAY * 4;
        done += nb;
        if (count + 6 > max && done < block_count) return -1;
    }
    w[count++] = signal_tag(1);
    return count;
}

/* -- the TPU, through a device ---------------------------------------------- */
enum { INSN_LO, INSN_HI, DATA, OUT, STATUS, LEVELS, CTRL, ERR_SEQ, PERF_CYCLES, PERF_MM_BEATS, PERF_MM_WSTALL };

typedef struct { device *dev; uint32_t base; uint64_t image_bytes; int8_t *ub; int32_t *raw; } tpu;

/* the instruction FIFO holds 512 words: a matrix too wide for one program at
 * this m (the head at m > 5) runs as several, each from its own first block */
#define PROGRAM_CHUNKS 96

static void tpu_matmul(core *c, const matrix *mx, const int8_t *xq, int m, int32_t *out) {
    tpu *t = c->state;
    device *d = t->dev;
    uint32_t inputs = inputs_at(t->base, t->image_bytes), outputs = inputs + (1u << 20);
    /* the input in the UB's layout: K-chunk-major, chunk k of row i at entry k*m + i */
    for (uint32_t k = 0; k < mx->k_tiles; k++)
        for (int i = 0; i < m; i++)
            memcpy(t->ub + ((size_t)k * m + i) * N_ARRAY, xq + (size_t)i * mx->K + k * N_ARRAY, N_ARRAY);
    d->ddr_write(d, inputs, t->ub, (size_t)mx->k_tiles * m * N_ARRAY);
    uint32_t per = ACC_ROWS / (uint32_t)m < N_BLOCKS_MAX ? ACC_ROWS / (uint32_t)m : N_BLOCKS_MAX;
    for (uint32_t first = 0; first < mx->n_blocks; first += per * PROGRAM_CHUNKS) {
        uint32_t span = mx->n_blocks - first < per * PROGRAM_CHUNKS ? mx->n_blocks - first : per * PROGRAM_CHUNKS;
        uint64_t words[512];
        int chunks, blocks[PROGRAM_CHUNKS];
        uint32_t obase[PROGRAM_CHUNKS];
        int count = core_program(mx, m, first, span, t->base, t->image_bytes, words, 512, &chunks, blocks, obase);
        if (count < 0) { fprintf(stderr, "%s: m=%d doesn't fit a program\n", mx->name, m); exit(1); }
        d->write32(d, CTRL, 1 | 4);                  /* RESET, CLEAR_PERF */
        d->write32(d, CTRL, 2);                      /* CLEAR_DONE */
        for (int i = 0; i < count; i++) {
            d->write32(d, INSN_LO, (uint32_t)words[i]);
            d->write32(d, INSN_HI, (uint32_t)(words[i] >> 32));
        }
        for (;;) {
            d->advance(d, 1u << 16);
            uint32_t st = d->read32(d, STATUS);
            if (st & 2) {
                fprintf(stderr, "%s: core error %u at instruction %u\n", mx->name, (st >> 8) & 0xFF,
                        d->read32(d, ERR_SEQ));
                exit(1);
            }
            if (st & 1) break;
        }
        c->beats += d->read32(d, PERF_MM_BEATS);
        c->weight_stalls += d->read32(d, PERF_MM_WSTALL);
        size_t words_out = (obase[chunks - 1] - outputs) / 4 + (size_t)blocks[chunks - 1] * m * N_ARRAY;
        d->ddr_read(d, outputs, t->raw, words_out * 4);
        /* each ACTIVATE wrote its blocks block-major: block b, row i, N_ARRAY words */
        uint32_t at = first;
        for (int ch = 0; ch < chunks; ch++) {
            const int32_t *r = t->raw + (obase[ch] - outputs) / 4;
            for (int b = 0; b < blocks[ch]; b++)
                for (int i = 0; i < m; i++)
                    memcpy(out + (size_t)i * mx->N + (size_t)(at + (uint32_t)b) * N_ARRAY,
                           r + ((size_t)b * m + i) * N_ARRAY, N_ARRAY * 4);
            at += (uint32_t)blocks[ch];
        }
        c->programs++;
    }
    c->tiles += (uint64_t)mx->k_tiles * mx->n_blocks;
}

static void tpu_image_read(core *c, uint64_t offset, void *dst, size_t n) {
    tpu *t = c->state;
    t->dev->ddr_read(t->dev, t->base + (uint32_t)offset, dst, n);
}

core *core_tpu(device *dev, uint32_t base, uint64_t image_bytes, const char *load_image) {
    tpu *t = calloc(1, sizeof *t);
    t->dev = dev;
    t->base = base;
    t->image_bytes = image_bytes;
    t->ub = malloc((size_t)UB_ENTRIES * N_ARRAY);
    t->raw = malloc(64u << 20);
    if (load_image) {
        FILE *f = fopen(load_image, "rb");
        if (!f) { perror(load_image); exit(1); }
        uint8_t *chunk = malloc(16u << 20);
        size_t got;
        uint64_t at = 0;
        while ((got = fread(chunk, 1, 16u << 20, f)) > 0) {
            dev->ddr_write(dev, base + (uint32_t)at, chunk, got);
            at += got;
        }
        fclose(f);
        free(chunk);
    }
    core *c = calloc(1, sizeof *c);
    c->matmul = tpu_matmul;
    c->image_read = tpu_image_read;
    c->state = t;
    return c;
}

/* -- the reference: exact int8 x int8 -> int32 from the image's tiles ------- */
typedef struct { const int8_t *image; } ref;

static void ref_matmul(core *c, const matrix *mx, const int8_t *xq, int m, int32_t *out) {
    const int8_t *image = ((ref *)c->state)->image;
    for (uint32_t b = 0; b < mx->n_blocks; b++) {
        for (int i = 0; i < m; i++) {
            int32_t acc[N_ARRAY] = {0};
            const int8_t *x = xq + (size_t)i * mx->K;
            const int8_t *tile = image + ((uint64_t)mx->tile + (uint64_t)b * mx->k_tiles) * TILE_BYTES;
            for (uint32_t k = 0; k < mx->k_tiles; k++, tile += TILE_BYTES, x += N_ARRAY)
                for (int r = 0; r < N_ARRAY; r++)
                    for (int col = 0; col < N_ARRAY; col++)
                        acc[col] += (int32_t)x[r] * tile[r * N_ARRAY + col];
            memcpy(out + (size_t)i * mx->N + (size_t)b * N_ARRAY, acc, sizeof acc);
        }
    }
    c->programs++;
    c->tiles += (uint64_t)mx->k_tiles * mx->n_blocks;
}

static void ref_image_read(core *c, uint64_t offset, void *dst, size_t n) {
    memcpy(dst, ((ref *)c->state)->image + offset, n);
}

core *core_ref(const char *image_path) {
    int fd = open(image_path, O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st)) { perror(image_path); return NULL; }
    ref *r = calloc(1, sizeof *r);
    r->image = mmap(0, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (r->image == MAP_FAILED) { perror("mmap"); return NULL; }
    core *c = calloc(1, sizeof *c);
    c->matmul = ref_matmul;
    c->image_read = ref_image_read;
    c->state = r;
    return c;
}

/* -- nothing: times the host's own work ------------------------------------- */
static void null_matmul(core *c, const matrix *mx, const int8_t *xq, int m, int32_t *out) {
    (void)xq;
    memset(out, 0, sizeof(int32_t) * (size_t)m * mx->N);
    c->programs++;
}

static void null_image_read(core *c, uint64_t offset, void *dst, size_t n) {
    (void)c; (void)offset;
    memset(dst, 0, n);
}

core *core_null(void) {
    core *c = calloc(1, sizeof *c);
    c->matmul = null_matmul;
    c->image_read = null_image_read;
    return c;
}

/* -- a core checked against another, every matmul ---------------------------- */
typedef struct { core *primary, *reference; uint64_t *compared, *mismatched; int32_t *want; size_t size; } checked;

static void checked_matmul(core *c, const matrix *mx, const int8_t *xq, int m, int32_t *out) {
    checked *k = c->state;
    size_t words = (size_t)m * mx->N;
    if (words > k->size) { free(k->want); k->want = malloc(4 * words); k->size = words; }
    k->primary->matmul(k->primary, mx, xq, m, out);
    k->reference->matmul(k->reference, mx, xq, m, k->want);
    (*k->compared)++;
    if (memcmp(out, k->want, 4 * words)) {
        (*k->mismatched)++;
        size_t bad = 0;
        for (size_t i = 0; i < words; i++) bad += out[i] != k->want[i];
        fprintf(stderr, "MISMATCH %s, m=%d: %zu of %zu words differ\n", mx->name, m, bad, words);
    }
    c->programs = k->primary->programs;
    c->tiles = k->primary->tiles;
    c->beats = k->primary->beats;
    c->weight_stalls = k->primary->weight_stalls;
}

static void checked_image_read(core *c, uint64_t offset, void *dst, size_t n) {
    checked *k = c->state;
    k->primary->image_read(k->primary, offset, dst, n);
}

core *core_checked(core *primary, core *reference, uint64_t *compared, uint64_t *mismatched) {
    checked *k = calloc(1, sizeof *k);
    k->primary = primary;
    k->reference = reference;
    k->compared = compared;
    k->mismatched = mismatched;
    core *c = calloc(1, sizeof *c);
    c->matmul = checked_matmul;
    c->image_read = checked_image_read;
    c->state = k;
    return c;
}
