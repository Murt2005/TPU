/* qwen-run: Qwen2.5-0.5B with its linear layers on a core
 *
 *   qwen-run --tables DIR --core ref:IMAGE | sim:TB_ISA[:IMAGE] | mmio | null
 *            [--generate N --ids 1,2,3]       greedy continuation of a prompt (token ids)
 *            [--score FILE --window L]        perplexity over FILE (int32 ids)
 *            [--programs FILE]                every program core_program builds (tests)
 *            [--log FILE]                     every matmul's int8 input and int32 output
 *            [--prefill M]                    prompt rows per pass (default 16)
 *
 * sim:TB_ISA:IMAGE loads IMAGE into the simulated DDR3 first. ids come from
 * software/qwen/tokenizer.py; text is printed with the exported vocabulary */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "qwen.h"

static void usage(void) {
    fprintf(stderr, "usage: qwen-run --tables DIR --core ref:IMAGE|sim:TB_ISA[:IMAGE]|mmio|null "
                    "[--generate N --ids a,b,c] [--score FILE --window L] [--programs FILE] [--log FILE]\n");
    exit(2);
}

static uint64_t file_size(const char *path) {
    struct stat st;
    return stat(path, &st) ? 0 : (uint64_t)st.st_size;
}

static void print_token(const tables *tb, int id) {
    fwrite(tb->token[id], 1, tb->token_len[id], stdout);
    fflush(stdout);
}

static int argmax(const float *v, int n) {
    int best = 0;
    for (int j = 1; j < n; j++)
        if (v[j] > v[best]) best = j;
    return best;
}

/* the programs for every matrix at m = 1..16, one block range each, as text */
static void dump_programs(const model *md, const char *path, uint32_t base, uint64_t image_bytes) {
    FILE *f = fopen(path, "w");
    uint64_t words[512];
    int chunks, blocks[512];
    uint32_t obase[512];
    for (int k = 0; k < md->layers * 4 + 1; k++)
        for (int m = 1; m <= 16; m++) {
            const matrix *mx = &md->mats[k];
            int count = core_program(mx, m, 0, mx->n_blocks, base, image_bytes, words, 512, &chunks, blocks, obase);
            if (count < 0) continue;                   /* needs more than one program at this m */
            fprintf(f, "%s %d", mx->name, m);
            for (int i = 0; i < count; i++) fprintf(f, " %016llx", (unsigned long long)words[i]);
            fprintf(f, "\n");
        }
    fclose(f);
}

int main(int argc, char **argv) {
    const char *dir = NULL, *core_spec = NULL, *ids_text = NULL, *score_path = NULL, *programs = NULL, *log_path = NULL;
    int generate = 0, window = 256, prefill = 16;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--tables") && i + 1 < argc) dir = argv[++i];
        else if (!strcmp(argv[i], "--core") && i + 1 < argc) core_spec = argv[++i];
        else if (!strcmp(argv[i], "--generate") && i + 1 < argc) generate = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--ids") && i + 1 < argc) ids_text = argv[++i];
        else if (!strcmp(argv[i], "--score") && i + 1 < argc) score_path = argv[++i];
        else if (!strcmp(argv[i], "--window") && i + 1 < argc) window = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--programs") && i + 1 < argc) programs = argv[++i];
        else if (!strcmp(argv[i], "--log") && i + 1 < argc) log_path = argv[++i];
        else if (!strcmp(argv[i], "--prefill") && i + 1 < argc) prefill = atoi(argv[++i]);
        else usage();
    }
    if (!dir || !core_spec) usage();
    tables tb;
    if (tables_load(&tb, dir)) return 1;

    char image[512];
    snprintf(image, sizeof image, "%s/qwen-ddr.bin", dir);
    uint64_t image_bytes = file_size(image);
    core *c = NULL;
    uint32_t base = 0;
    if (!strncmp(core_spec, "ref:", 4)) {
        c = core_ref(core_spec + 4);
    } else if (!strcmp(core_spec, "null")) {
        c = core_null();
    } else if (!strncmp(core_spec, "sim:", 4)) {
        char binary[512], *load;
        snprintf(binary, sizeof binary, "%s", core_spec + 4);
        load = strchr(binary, ':');
        if (load) *load++ = 0;
        device *d = device_sim(binary);
        if (!d) return 1;
        base = d->ddr_low;
        c = core_tpu(d, base, image_bytes, load);
    } else if (!strcmp(core_spec, "mmio")) {
        device *d = device_mmio();
        if (!d) return 1;
        base = d->ddr_low;
        if (base + image_bytes + (16u << 20) > d->ddr_high) {
            fprintf(stderr, "the weights (%llu bytes) don't fit the DDR3 window [%#x, %#x)\n",
                    (unsigned long long)image_bytes, d->ddr_low, d->ddr_high);
            return 1;
        }
        c = core_tpu(d, base, image_bytes, NULL);
    }
    if (!c) usage();

    model md;
    if (model_init(&md, &tb, c, 2048)) { fprintf(stderr, "out of memory\n"); return 1; }
    if (programs) { dump_programs(&md, programs, base, image_bytes); return 0; }
    if (log_path) md.log = fopen(log_path, "wb");
    float *logits = malloc(sizeof(float) * (size_t)prefill * md.vocab);

    if (ids_text) {
        int ids[2048], n = 0;
        for (char *p = (char *)ids_text; *p && n < 2048;) {
            ids[n++] = (int)strtol(p, &p, 10);
            while (*p == ',' || *p == ' ') p++;
        }
        for (int i = 0; i < n; i++) print_token(&tb, ids[i]);
        double t0 = now_seconds();
        for (int at = 0; at < n; at += prefill) {
            int m = n - at < prefill ? n - at : prefill;
            md.host_seconds = md.core_seconds = 0;
            model_forward(&md, ids + at, m, logits);
            if (at + m == n) {
                fprintf(stderr, "\n[prompt %d tokens: %.2f s; host %.2f s, core %.2f s]\n", n, now_seconds() - t0,
                        md.host_seconds, md.core_seconds);
                int next = argmax(logits + (size_t)(m - 1) * md.vocab, md.vocab);
                printf("\n>>> ");
                for (int step = 0; step < generate; step++) {
                    print_token(&tb, next);
                    printf("[%d]", next);
                    md.host_seconds = md.core_seconds = 0;
                    double t1 = now_seconds();
                    model_forward(&md, &next, 1, logits);
                    fprintf(stderr, " (%.2f s: host %.2f, core %.2f)", now_seconds() - t1, md.host_seconds,
                            md.core_seconds);
                    next = argmax(logits, md.vocab);
                }
                printf("\n");
            }
        }
    }

    if (score_path) {
        FILE *f = fopen(score_path, "rb");
        if (!f) { perror(score_path); return 1; }
        uint64_t count = file_size(score_path) / 4;
        int *all = malloc(sizeof(int) * count);
        if (fread(all, 4, count, f) != count) return 1;
        fclose(f);
        double nll = 0;
        uint64_t scored = 0;
        for (uint64_t w = 0; w + (uint64_t)window <= count; w += (uint64_t)window) {
            md.pos = 0;
            for (int at = 0; at < window; at += prefill) {
                int m = window - at < prefill ? window - at : prefill;
                model_forward(&md, all + w + at, m, logits);
                for (int i = 0; i < m; i++) {
                    if (at + i + 1 >= window) break;
                    const float *row = logits + (size_t)i * md.vocab;
                    float peak = row[argmax(row, md.vocab)];
                    double sum = 0;
                    for (int j = 0; j < md.vocab; j++) sum += exp((double)(row[j] - peak));
                    nll -= (double)(row[all[w + at + i + 1]] - peak) - log(sum);
                    scored++;
                }
            }
            fprintf(stderr, "window %llu: perplexity so far %.4f\n", (unsigned long long)(w / window + 1),
                    exp(nll / scored));
        }
        printf("perplexity %.4f over %llu tokens\n", exp(nll / scored), (unsigned long long)scored);
    }
    if (md.log) fclose(md.log);
    fprintf(stderr, "core: %llu programs, %llu tiles, %llu MM beats, %llu weight-stall cycles\n",
            (unsigned long long)c->programs, (unsigned long long)c->tiles, (unsigned long long)c->beats,
            (unsigned long long)c->weight_stalls);
    return 0;
}
