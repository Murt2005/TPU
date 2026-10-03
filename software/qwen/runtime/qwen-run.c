/* qwen-run: Qwen2.5-0.5B with its linear layers on a core
 *
 *   qwen-run --tables DIR --core ref:IMAGE | sim:TB_ISA[:IMAGE] | mmio[:IMAGE] | null
 *            [--check ref:IMAGE]              every matmul also by the exact reference, compared
 *            [--generate N --ids 1,2,3]       greedy continuation of a prompt (token ids)
 *            [--score FILE --window L]        perplexity over FILE (int32 ids)
 *            [--programs FILE]                every program core_program builds (tests)
 *            [--log FILE]                     every matmul's int8 input and int32 output
 *            [--prefill M]                    prompt rows per pass (default 16)
 *            [--serve]                        answer requests on stdin (chat.py), weights loaded once
 *
 * --serve speaks lines: in "G <max tokens> <id>,<id>,..." (a fresh context each
 * time), "S" (stop the reply being made) or "Q"; out "READY" once, then per
 * request "T <id>" for each token as it's made and "E <tokens> <prompt seconds>
 * <generate seconds>" at the end. generation also stops at <|endoftext|> or <|im_end|>
 *
 * sim:TB_ISA:IMAGE and mmio:IMAGE load IMAGE into (simulated) DDR3 first. ids come from
 * software/qwen/tokenizer.py; text is printed with the exported vocabulary */
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <unistd.h>

#include "qwen.h"

static int argmax(const float *v, int n) {
    int best = 0;
    for (int j = 1; j < n; j++)
        if (v[j] > v[best]) best = j;
    return best;
}

/* LED9 flashes as each token goes out (the chat demo): the GHRD's led_pio drives
 * LEDR[9:1], so LED9 is its bit 8, at 0xFF210040 on the lightweight bridge. on as
 * a token is printed, off two layers into the next one (~0.1 s), so it costs nothing */
static volatile uint32_t *leds;

static void led9(int on) {
    if (leds) *leds = on ? 1u << 8 : 0;
}

static void led9_off_at_layer_2(int layer) {
    if (layer == 2) led9(0);
}

static void leds_map(void) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) return;
    void *page = mmap(0, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0xFF210000);
    if (page != MAP_FAILED) leds = (volatile uint32_t *)((volatile uint8_t *)page + 0x40);
}

#define EOS_TEXT 151643     /* <|endoftext|> */
#define EOS_TURN 151645     /* <|im_end|> */

/* stdin, a line at a time, read with read() so a stop can be polled for between
 * tokens without blocking (select) and without stdio's buffer hiding bytes */
typedef struct { char buf[1 << 20]; size_t len; } input;

/* the next whole line into line, or 0 if none is complete; wait = block for one */
static int next_line(input *in, char *line, size_t max, int wait) {
    for (;;) {
        for (size_t i = 0; i < in->len; i++)
            if (in->buf[i] == '\n' || in->buf[i] == '\r') {
                size_t n = i < max - 1 ? i : max - 1;
                memcpy(line, in->buf, n);
                line[n] = 0;
                memmove(in->buf, in->buf + i + 1, in->len - i - 1);
                in->len -= i + 1;
                if (n) return 1;                         /* skip empty lines */
                i = (size_t)-1;
            }
        if (!wait) {
            fd_set fds;
            struct timeval now = {0, 0};
            FD_ZERO(&fds);
            FD_SET(0, &fds);
            if (select(1, &fds, NULL, NULL, &now) <= 0) return 0;
        }
        ssize_t got = read(0, in->buf + in->len, sizeof in->buf - in->len);
        if (got <= 0) return -1;
        in->len += (size_t)got;
        if (!wait) {
            /* one read's worth, then look again without waiting */
            for (size_t i = 0; i < in->len; i++)
                if (in->buf[i] == '\n' || in->buf[i] == '\r') goto again;
            return 0;
        }
    again:;
    }
}

/* chat.py's requests: one prompt in, its tokens out as they're made; "S" between
 * tokens stops the reply early (chat.py's stop sequence turned up) */
static void serve(model *md, int prefill) {
    static input in;
    char *line = malloc(1 << 20);
    int *ids = malloc(sizeof(int) * (size_t)md->max_ctx);
    float *logits = malloc(sizeof(float) * (size_t)prefill * md->vocab);
    md->layer_hook = led9_off_at_layer_2;
    led9(0);
    printf("READY\n");
    fflush(stdout);
    while (next_line(&in, line, 1 << 20, 1) > 0) {
        if (line[0] == 'Q') break;
        if (line[0] != 'G') continue;                    /* a stray stop, or noise */
        char *p = line + 1;
        int max_tokens = (int)strtol(p, &p, 10), n = 0;
        while (*p && n < md->max_ctx) {
            while (*p == ' ' || *p == ',') p++;
            if (!*p) break;
            ids[n++] = (int)strtol(p, &p, 10);
        }
        if (n == 0) { printf("E 0 0 0\n"); fflush(stdout); continue; }
        if (n + max_tokens > md->max_ctx) max_tokens = md->max_ctx - n;
        md->pos = 0;
        double t0 = now_seconds();
        int m = 0;
        for (int at = 0; at < n; at += prefill) {
            m = n - at < prefill ? n - at : prefill;
            model_forward(md, ids + at, m, logits);
        }
        double t1 = now_seconds();
        int next = argmax(logits + (size_t)(m - 1) * md->vocab, md->vocab), made = 0, quit = 0;
        while (made < max_tokens && next != EOS_TEXT && next != EOS_TURN) {
            printf("T %d\n", next);
            fflush(stdout);
            led9(1);
            made++;
            if (made == max_tokens) break;
            char pending[64];
            int got = next_line(&in, pending, sizeof pending, 0);
            if (got < 0) { quit = 1; break; }
            if (got > 0 && (pending[0] == 'S' || pending[0] == 'Q')) { quit = pending[0] == 'Q'; break; }
            model_forward(md, &next, 1, logits);
            next = argmax(logits, md->vocab);
        }
        led9(0);
        printf("E %d %.3f %.3f\n", made, t1 - t0, now_seconds() - t1);
        fflush(stdout);
        if (quit) break;
    }
    free(line);
    free(ids);
    free(logits);
}

static void usage(void) {
    fprintf(stderr, "usage: qwen-run --tables DIR --core ref:IMAGE|sim:TB_ISA[:IMAGE]|mmio[:IMAGE]|null "
                    "[--check ref:IMAGE] [--generate N --ids a,b,c] [--score FILE --window L] [--programs FILE] "
                    "[--log FILE] [--prefill M]\n");
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
    const char *check_spec = NULL;
    int generate = 0, window = 256, prefill = 16, serving = 0;
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
        else if (!strcmp(argv[i], "--check") && i + 1 < argc) check_spec = argv[++i];
        else if (!strcmp(argv[i], "--serve")) serving = 1;
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
    } else if (!strncmp(core_spec, "mmio", 4) && (core_spec[4] == 0 || core_spec[4] == ':')) {
        const char *load = core_spec[4] == ':' ? core_spec + 5 : NULL;
        device *d = device_mmio();
        if (!d) return 1;
        base = d->ddr_low;
        if (base + image_bytes + (16u << 20) > d->ddr_high) {
            fprintf(stderr, "the weights (%llu bytes) don't fit the DDR3 window [%#x, %#x)\n",
                    (unsigned long long)image_bytes, d->ddr_low, d->ddr_high);
            return 1;
        }
        leds_map();
        double t0 = now_seconds();
        c = core_tpu(d, base, image_bytes, load);
        if (load) fprintf(stderr, "%s into DDR3 at %#x: %.1f s\n", load, base, now_seconds() - t0);
    }
    if (!c) usage();
    uint64_t compared = 0, mismatched = 0;
    if (check_spec) {
        if (strncmp(check_spec, "ref:", 4)) usage();
        core *reference = core_ref(check_spec + 4);
        if (!reference) return 1;
        c = core_checked(c, reference, &compared, &mismatched);
    }

    model md;
    if (model_init(&md, &tb, c, 2048)) { fprintf(stderr, "out of memory\n"); return 1; }
    if (programs) { dump_programs(&md, programs, base, image_bytes); return 0; }
    if (log_path) md.log = fopen(log_path, "wb");
    if (serving) { serve(&md, prefill); return 0; }
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
    if (check_spec) {
        fprintf(stderr, "checked: %llu matmuls against the exact reference, %llu mismatched\n",
                (unsigned long long)compared, (unsigned long long)mismatched);
        return mismatched != 0;
    }
    return 0;
}
