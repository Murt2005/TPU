/* export.py's qwen-host.bin (named float32 / int32 arrays) and qwen-vocab.bin */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "qwen.h"

static void *read_file(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return NULL; }
    fseek(f, 0, SEEK_END);
    *size = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    void *buf = malloc(*size);
    if (!buf || fread(buf, 1, *size, f) != *size) { fclose(f); free(buf); return NULL; }
    fclose(f);
    return buf;
}

int tables_load(tables *tb, const char *dir) {
    char path[512];
    size_t size;
    snprintf(path, sizeof path, "%s/qwen-host.bin", dir);
    uint8_t *p = read_file(path, &size), *end = p + size;
    if (!p || memcmp(p, "QWH1", 4)) { fprintf(stderr, "%s: not a QWH1 table\n", path); return -1; }
    memcpy(&tb->count, p + 4, 4);
    p += 8;
    tb->t = calloc((size_t)tb->count, sizeof(table));
    for (int i = 0; i < tb->count; i++) {
        uint16_t len;
        memcpy(&len, p, 2);
        memcpy(tb->t[i].name, p + 2, len < 63 ? len : 63);
        p += 2 + len;
        tb->t[i].kind = p[0];
        memcpy(&tb->t[i].count, p + 1, 4);
        p += 5;
        tb->t[i].data = malloc(4 * (size_t)tb->t[i].count);       /* aligned copy */
        memcpy(tb->t[i].data, p, 4 * (size_t)tb->t[i].count);
        p += 4 * (size_t)tb->t[i].count;
        if (p > end) { fprintf(stderr, "%s: truncated\n", path); return -1; }
    }

    snprintf(path, sizeof path, "%s/qwen-vocab.bin", dir);
    p = read_file(path, &size);
    if (!p || memcmp(p, "QWV1", 4)) { fprintf(stderr, "%s: not a QWV1 vocabulary\n", path); return -1; }
    memcpy(&tb->vocab, p + 4, 4);
    p += 8;
    tb->token = calloc((size_t)tb->vocab, sizeof(uint8_t *));
    tb->token_len = calloc((size_t)tb->vocab, sizeof(uint16_t));
    for (int i = 0; i < tb->vocab; i++) {
        memcpy(&tb->token_len[i], p, 2);
        tb->token[i] = p + 2;
        p += 2 + tb->token_len[i];
    }
    return 0;
}

static const table *find(const tables *tb, const char *name) {
    for (int i = 0; i < tb->count; i++)
        if (!strcmp(tb->t[i].name, name)) return &tb->t[i];
    return NULL;
}

const float *table_f32(const tables *tb, const char *name, uint32_t *count) {
    const table *t = find(tb, name);
    if (!t || t->kind != 0) return NULL;
    if (count) *count = t->count;
    return t->data;
}

int table_i32(const tables *tb, const char *name, int index) {
    const table *t = find(tb, name);
    if (!t || t->kind != 1 || (uint32_t)index >= t->count) {
        fprintf(stderr, "qwen-host.bin: no int32 %s[%d]\n", name, index);
        exit(1);
    }
    return ((const int32_t *)t->data)[index];
}
