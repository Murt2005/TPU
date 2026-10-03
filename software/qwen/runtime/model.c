/* Qwen2's host arithmetic in float32, following qwen.py step for step: the
 * embedding read from the head's int8 tiles, RMSNorm, the q/k/v split, RoPE
 * (rotate-half), attention over the KV cache (14 query heads on 2 KV heads),
 * SiLU(gate) x up, residuals, the final norm; and around every linear layer
 * qwen.CoreLinear's quantize and dequantize, with the core in between */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "qwen.h"

static const char *PARTS[4] = {"qkv", "o", "gate_up", "down"};

double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void load_matrix(matrix *mx, const tables *tb, const char *name) {
    char key[96];
    snprintf(mx->name, sizeof mx->name, "%s", name);
    snprintf(key, sizeof key, "%s.tile", name);
    mx->tile = (uint32_t)table_i32(tb, key, 0);
    snprintf(key, sizeof key, "%s.shape", name);
    mx->k_tiles = (uint32_t)table_i32(tb, key, 0);
    mx->n_blocks = (uint32_t)table_i32(tb, key, 1);
    mx->K = (int)mx->k_tiles * 8;
    mx->N = (int)mx->n_blocks * 8;
    snprintf(key, sizeof key, "%s.wscale", name);
    mx->wscale = table_f32(tb, key, NULL);
    snprintf(key, sizeof key, "%s.smooth", name);
    mx->smooth = table_f32(tb, key, NULL);
    snprintf(key, sizeof key, "%s.bias", name);
    mx->bias = table_f32(tb, key, NULL);
}

int model_init(model *md, const tables *tb, core *c, int max_ctx) {
    memset(md, 0, sizeof *md);
    md->layers = table_i32(tb, "cfg.layers", 0);
    md->d = table_i32(tb, "cfg.hidden", 0);
    md->heads = table_i32(tb, "cfg.heads", 0);
    md->kv_heads = table_i32(tb, "cfg.kv_heads", 0);
    md->inter = table_i32(tb, "cfg.inter", 0);
    md->vocab = table_i32(tb, "cfg.vocab", 0);
    md->n = table_i32(tb, "n", 0);
    md->head_dim = md->d / md->heads;
    md->eps = table_f32(tb, "cfg.eps", NULL)[0];
    float theta = table_f32(tb, "cfg.theta", NULL)[0];
    md->max_ctx = max_ctx;
    md->core = c;
    md->mats = calloc((size_t)md->layers * 4 + 1, sizeof(matrix));
    md->input_norm = calloc((size_t)md->layers, sizeof(float *));
    md->post_norm = calloc((size_t)md->layers, sizeof(float *));
    char name[64];
    for (int i = 0; i < md->layers; i++) {
        for (int p = 0; p < 4; p++) {
            snprintf(name, sizeof name, "layer%d.%s", i, PARTS[p]);
            load_matrix(&md->mats[i * 4 + p], tb, name);
        }
        snprintf(name, sizeof name, "layer%d.input_norm", i);
        md->input_norm[i] = table_f32(tb, name, NULL);
        snprintf(name, sizeof name, "layer%d.post_norm", i);
        md->post_norm[i] = table_f32(tb, name, NULL);
    }
    load_matrix(&md->mats[md->layers * 4], tb, "head");
    md->final_norm = table_f32(tb, "final_norm", NULL);
    md->inv_freq = malloc(sizeof(float) * (size_t)(md->head_dim / 2));
    for (int j = 0; j < md->head_dim / 2; j++)          /* as qwen.py: in float64, then float32 */
        md->inv_freq[j] = (float)(1.0 / pow((double)theta, (double)(2 * j) / md->head_dim));
    size_t kv = (size_t)md->layers * max_ctx * md->kv_heads * md->head_dim;
    md->k_cache = calloc(kv, sizeof(float));
    md->v_cache = calloc(kv, sizeof(float));
    if (!md->k_cache || !md->v_cache) return -1;
    return 0;
}

static void rms_norm(const float *x, const float *g, float eps, int d, float *out) {
    float ss = 0;
    for (int j = 0; j < d; j++) ss += x[j] * x[j];
    float r = sqrtf(ss / (float)d + eps);
    for (int j = 0; j < d; j++) out[j] = (x[j] / r) * g[j];
}

/* qwen.CoreLinear: x (m x K) -> y (m x N): smooth, int8 per row, the core, dequantize */
static void linear(model *md, const matrix *mx, const float *x, int m, float *y) {
    int8_t *xq = malloc((size_t)m * mx->K);
    float *xscale = malloc(sizeof(float) * (size_t)m), *row = malloc(sizeof(float) * (size_t)mx->K);
    int32_t *acc = malloc(sizeof(int32_t) * (size_t)m * mx->N);
    for (int i = 0; i < m; i++) {
        float peak = 0;
        for (int j = 0; j < mx->K; j++) {
            row[j] = mx->smooth ? x[(size_t)i * mx->K + j] / mx->smooth[j] : x[(size_t)i * mx->K + j];
            float a = fabsf(row[j]);
            if (a > peak) peak = a;
        }
        float scale = peak / 127.0f;
        if (scale < 1e-12f) scale = 1e-12f;
        xscale[i] = scale;
        for (int j = 0; j < mx->K; j++) {
            float q = rintf(row[j] / scale);            /* round half to even, as np.rint */
            xq[(size_t)i * mx->K + j] = (int8_t)(q > 127 ? 127 : q < -127 ? -127 : q);
        }
    }
    double t0 = now_seconds();
    md->core->matmul(md->core, mx, xq, m, acc);
    md->core_seconds += now_seconds() - t0;
    if (md->log) {
        uint32_t head[4] = {(uint32_t)(mx - md->mats), (uint32_t)m, (uint32_t)mx->K, (uint32_t)mx->N};
        fwrite(head, 4, 4, md->log);
        fwrite(xq, 1, (size_t)m * mx->K, md->log);
        fwrite(acc, 4, (size_t)m * mx->N, md->log);
    }
    for (int i = 0; i < m; i++)
        for (int j = 0; j < mx->N; j++) {
            float v = (float)acc[(size_t)i * mx->N + j] * xscale[i] * mx->wscale[j];
            y[(size_t)i * mx->N + j] = mx->bias ? v + mx->bias[j] : v;
        }
    free(xq);
    free(xscale);
    free(row);
    free(acc);
}

/* rotate-half RoPE on one head vector at position pos */
static void rope(const model *md, float *v, int pos) {
    int half = md->head_dim / 2;
    float tmp[256];
    for (int j = 0; j < md->head_dim; j++) {
        float angle = (float)pos * md->inv_freq[j % half];
        float rotated = j < half ? -v[j + half] : v[j - half];
        tmp[j] = v[j] * cosf(angle) + rotated * sinf(angle);
    }
    memcpy(v, tmp, sizeof(float) * (size_t)md->head_dim);
}

void model_forward(model *md, const int *ids, int m, float *logits) {
    double t0 = now_seconds(), core_before = md->core_seconds;
    int d = md->d, hd = md->head_dim, qs = md->heads * hd, kvs = md->kv_heads * hd;
    int group = md->heads / md->kv_heads, start = md->pos;
    matrix *head = &md->mats[md->layers * 4];
    float *x = malloc(sizeof(float) * (size_t)m * d), *h = malloc(sizeof(float) * (size_t)m * d);
    float *qkv = malloc(sizeof(float) * (size_t)m * (qs + 2 * kvs)), *attn = malloc(sizeof(float) * (size_t)m * qs);
    float *proj = malloc(sizeof(float) * (size_t)m * d);
    float *gu = malloc(sizeof(float) * (size_t)m * 2 * md->inter), *act = malloc(sizeof(float) * (size_t)m * md->inter);
    float *scores = malloc(sizeof(float) * (size_t)(start + m));
    int8_t *column = malloc((size_t)head->k_tiles * 64);

    /* the embedding: token t is column t % 8 of the head's block t / 8, every K-tile, every row */
    for (int i = 0; i < m; i++) {
        int t = ids[i], b = t / 8, c = t % 8;
        md->core->image_read(md->core, ((uint64_t)head->tile + (uint64_t)b * head->k_tiles) * 64, column,
                             (size_t)head->k_tiles * 64);
        for (int k = 0; k < (int)head->k_tiles; k++)
            for (int r = 0; r < 8; r++)
                x[(size_t)i * d + k * 8 + r] = (float)column[(k * 8 + r) * 8 + c] * head->wscale[t];
    }

    for (int l = 0; l < md->layers; l++) {
        if (md->layer_hook) md->layer_hook(l);
        matrix *mx = &md->mats[l * 4];
        float *kc = md->k_cache + (size_t)l * md->max_ctx * kvs, *vc = md->v_cache + (size_t)l * md->max_ctx * kvs;
        for (int i = 0; i < m; i++) rms_norm(x + (size_t)i * d, md->input_norm[l], md->eps, d, h + (size_t)i * d);
        linear(md, &mx[0], h, m, qkv);
        for (int i = 0; i < m; i++) {
            float *row = qkv + (size_t)i * (qs + 2 * kvs);
            int pos = start + i;
            for (int hh = 0; hh < md->heads; hh++) rope(md, row + hh * hd, pos);
            for (int kh = 0; kh < md->kv_heads; kh++) rope(md, row + qs + kh * hd, pos);
            memcpy(kc + (size_t)pos * kvs, row + qs, sizeof(float) * (size_t)kvs);
            memcpy(vc + (size_t)pos * kvs, row + qs + kvs, sizeof(float) * (size_t)kvs);
        }
        /* attention: row i sees positions 0 .. start + i */
        for (int i = 0; i < m; i++) {
            const float *q = qkv + (size_t)i * (qs + 2 * kvs);
            int span = start + i + 1;
            for (int hh = 0; hh < md->heads; hh++) {
                int kh = hh / group;
                float peak = -INFINITY;
                for (int s = 0; s < span; s++) {
                    const float *k = kc + (size_t)s * kvs + kh * hd;
                    float dot = 0;
                    for (int j = 0; j < hd; j++) dot += q[hh * hd + j] * k[j];
                    scores[s] = dot / sqrtf((float)hd);
                    if (scores[s] > peak) peak = scores[s];
                }
                float sum = 0;
                for (int s = 0; s < span; s++) { scores[s] = expf(scores[s] - peak); sum += scores[s]; }
                float *out = attn + (size_t)i * qs + hh * hd;
                memset(out, 0, sizeof(float) * (size_t)hd);
                for (int s = 0; s < span; s++) {
                    float p = scores[s] / sum;
                    const float *v = vc + (size_t)s * kvs + kh * hd;
                    for (int j = 0; j < hd; j++) out[j] += p * v[j];
                }
            }
        }
        linear(md, &mx[1], attn, m, proj);
        for (size_t j = 0; j < (size_t)m * d; j++) x[j] += proj[j];
        for (int i = 0; i < m; i++) rms_norm(x + (size_t)i * d, md->post_norm[l], md->eps, d, h + (size_t)i * d);
        linear(md, &mx[2], h, m, gu);
        for (int i = 0; i < m; i++)
            for (int j = 0; j < md->inter; j++) {
                float g = gu[(size_t)i * 2 * md->inter + j], u = gu[(size_t)i * 2 * md->inter + md->inter + j];
                act[(size_t)i * md->inter + j] = g / (1.0f + expf(-g)) * u;
            }
        linear(md, &mx[3], act, m, proj);
        for (size_t j = 0; j < (size_t)m * d; j++) x[j] += proj[j];
    }
    for (int i = 0; i < m; i++) rms_norm(x + (size_t)i * d, md->final_norm, md->eps, d, h + (size_t)i * d);
    linear(md, head, h, m, logits);
    md->pos += m;
    md->host_seconds += (now_seconds() - t0) - (md->core_seconds - core_before);
    free(x); free(h); free(qkv); free(attn); free(proj); free(gu); free(act); free(scores); free(column);
}
