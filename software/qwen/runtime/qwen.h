/* Qwen2.5-0.5B's host runtime: everything but the linear layers, which a core
 * computes. The specification is software/qwen/qwen.py (the arithmetic) and
 * core_runtime.py (the programs); this follows them operation for operation.
 *
 * cores: "ref"  an exact int8 matmul in C, reading the weight image file
 *        "sim"  the Verilator core (tb_isa) over its pipe, weights in its DDR3
 *        "mmio" the DE1-SoC's core through /dev/mem, weights in DDR3
 *        "null" no matmul at all (zeros), to time the host's own work */
#ifndef QWEN_H
#define QWEN_H

#include <stddef.h>
#include <stdint.h>

/* -- tables (export.py's qwen-host.bin, qwen-vocab.bin) -------------------- */
typedef struct {
    char name[64];
    int kind;                       /* 0 float32, 1 int32 */
    uint32_t count;
    void *data;
} table;

typedef struct {
    table *t;
    int count;
    uint8_t **token;                /* vocab: bytes per token */
    uint16_t *token_len;
    int vocab;
} tables;

int tables_load(tables *tb, const char *dir);
const float *table_f32(const tables *tb, const char *name, uint32_t *count);   /* NULL if absent */
int table_i32(const tables *tb, const char *name, int index);

/* -- a matrix the core multiplies by -------------------------------------- */
typedef struct {
    char name[32];
    int K, N;                       /* inputs, outputs */
    uint32_t tile, k_tiles, n_blocks;
    const float *wscale, *smooth, *bias;
} matrix;

/* -- the register and DDR3 transport, for sim and mmio -------------------- */
typedef struct device device;
struct device {
    void (*write32)(device *, int reg, uint32_t value);
    uint32_t (*read32)(device *, int reg);
    void (*ddr_write)(device *, uint32_t address, const void *data, size_t n);
    void (*ddr_read)(device *, uint32_t address, void *data, size_t n);
    void (*advance)(device *, uint32_t cycles);     /* the simulator's clock; no-op on the board */
    uint32_t ddr_low, ddr_high;                       /* where the host may put things */
    void *state;
};
device *device_sim(const char *binary);
device *device_mmio(void);

/* -- a core: one linear layer's int8 matmul, and reads of the weight image - */
typedef struct core core;
struct core {
    /* xq: m rows of K int8; out: m rows of N int32 */
    void (*matmul)(core *, const matrix *, const int8_t *xq, int m, int32_t *out);
    /* bytes of the weight image (for the embedding, read from the head's tiles) */
    void (*image_read)(core *, uint64_t offset, void *dst, size_t n);
    uint64_t programs, tiles, beats, weight_stalls;  /* counters */
    FILE *profile;                                   /* the profiler's record (core_profile_open), or NULL */
    void *state;
};
core *core_ref(const char *image_path);
core *core_null(void);
core *core_tpu(device *dev, uint32_t base, uint64_t image_bytes, const char *load_image);
/* record the core's instruction profiler (rtl/common/profiler.sv) to path, in
 * host/tpu/profile.py's format: every program as pushed, its events, and marks.
 * TPU cores only; -1 otherwise */
int core_profile_open(core *c, const char *path);
void core_profile_mark(core *c, const char *label, double seconds);
void core_profile_close(core *c);
/* primary's results, each also computed by reference and compared word for word */
core *core_checked(core *primary, core *reference, uint64_t *compared, uint64_t *mismatched);
/* the program for output blocks [first, first + count) of mx on m rows; -1 if it won't fit max words */
int core_program(const matrix *mx, int m, uint32_t first, uint32_t count, uint32_t base, uint64_t image_bytes,
                 uint64_t *words, int max, int *chunks, int *chunk_blocks, uint32_t *chunk_obase);

/* -- the model ------------------------------------------------------------ */
typedef struct {
    int layers, d, heads, kv_heads, head_dim, inter, vocab, max_ctx, n;
    float eps, *inv_freq;
    matrix *mats;                   /* layers x {qkv, o, gate_up, down}, then the head */
    const float **input_norm, **post_norm, *final_norm;
    float *k_cache, *v_cache;       /* layers x max_ctx x kv_heads*head_dim */
    int pos;                        /* tokens in the cache */
    core *core;
    void *log;                      /* FILE *: every matmul's int8 input and int32 output */
    double host_seconds, core_seconds;
    void (*layer_hook)(int layer);  /* called as each layer starts, if set */
} model;

int model_init(model *md, const tables *tb, core *c, int max_ctx);
/* logits for the m tokens after those in the cache (rows of vocab floats), cache extended */
void model_forward(model *md, const int *ids, int m, float *logits);
double now_seconds(void);

#endif
