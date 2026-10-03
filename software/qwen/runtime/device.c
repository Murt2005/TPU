/* the core's registers and DDR3: the Verilator model over tb_isa's pipe
 * protocol (W/R/D/G/T, as host/tpu/isa_device.py speaks it), or the DE1-SoC
 * through /dev/mem (lightweight bridge at 0xFF200000; the DDR3 window Linux was
 * booted without, uncached) */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#include "qwen.h"

/* -- Verilator ------------------------------------------------------------ */
typedef struct { FILE *to, *from; pid_t pid; } sim;

static void sim_flush(sim *s) { fflush(s->to); }

static void sim_get(sim *s, void *p, size_t n) {
    sim_flush(s);
    if (fread(p, 1, n, s->from) != n) { fprintf(stderr, "tb_isa exited\n"); exit(1); }
}

static void sim_write32(device *d, int reg, uint32_t v) {
    sim *s = d->state;
    uint8_t cmd[6] = {'W', (uint8_t)reg};
    memcpy(cmd + 2, &v, 4);
    fwrite(cmd, 1, 6, s->to);
}

static uint32_t sim_read32(device *d, int reg) {
    sim *s = d->state;
    uint8_t cmd[2] = {'R', (uint8_t)reg};
    uint32_t v;
    fwrite(cmd, 1, 2, s->to);
    sim_get(s, &v, 4);
    return v;
}

static void sim_ddr_write(device *d, uint32_t a, const void *data, size_t n) {
    sim *s = d->state;
    uint32_t len = (uint32_t)n;
    fputc('D', s->to);
    fwrite(&a, 4, 1, s->to);
    fwrite(&len, 4, 1, s->to);
    fwrite(data, 1, n, s->to);
}

static void sim_ddr_read(device *d, uint32_t a, void *data, size_t n) {
    sim *s = d->state;
    uint32_t len = (uint32_t)n;
    fputc('G', s->to);
    fwrite(&a, 4, 1, s->to);
    fwrite(&len, 4, 1, s->to);
    sim_get(s, data, n);
}

static void sim_advance(device *d, uint32_t cycles) {
    sim *s = d->state;
    fputc('T', s->to);
    fwrite(&cycles, 4, 1, s->to);
}

device *device_sim(const char *binary) {
    int down[2], up[2];
    if (pipe(down) || pipe(up)) return NULL;
    pid_t pid = fork();
    if (pid == 0) {
        dup2(down[0], 0);
        dup2(up[1], 1);
        close(down[1]);
        close(up[0]);
        execl(binary, binary, (char *)NULL);
        perror(binary);
        _exit(127);
    }
    close(down[0]);
    close(up[1]);
    sim *s = calloc(1, sizeof *s);
    s->to = fdopen(down[1], "wb");
    s->from = fdopen(up[0], "rb");
    s->pid = pid;
    setvbuf(s->to, NULL, _IOFBF, 1 << 20);
    uint32_t params[5];
    sim_get(s, params, sizeof params);                /* N, WMEM, UB, ACC, PARAM */
    device *d = calloc(1, sizeof *d);
    d->write32 = sim_write32;
    d->read32 = sim_read32;
    d->ddr_write = sim_ddr_write;
    d->ddr_read = sim_ddr_read;
    d->advance = sim_advance;
    d->ddr_low = 0;
    d->ddr_high = 0x40000000u;
    d->state = s;
    fputc('M', s->to);                                /* fixed DDR3 timing: fast */
    fputc(0, s->to);
    return d;
}

/* -- the DE1-SoC ---------------------------------------------------------- */
#define LWH2F_BASE 0xFF200000u
#define DDR_LOW    0x10000000u       /* booted with mem=256M */
#define DDR_HIGH   0x3F000000u       /* Terasic's console framebuffer above */

typedef struct { volatile uint32_t *regs; volatile uint8_t *ddr; } mmio;

static void mmio_write32(device *d, int reg, uint32_t v) { ((mmio *)d->state)->regs[reg] = v; }
static uint32_t mmio_read32(device *d, int reg) { return ((mmio *)d->state)->regs[reg]; }

/* the window is mapped uncached (strongly ordered): no unaligned accesses there */
static void mmio_ddr_write(device *d, uint32_t a, const void *data, size_t n) {
    volatile uint8_t *dst = ((mmio *)d->state)->ddr + (a - DDR_LOW);
    const uint8_t *src = data;
    if (((uintptr_t)dst | (uintptr_t)src | n) % 4 == 0)
        for (size_t i = 0; i < n; i += 4) *(volatile uint32_t *)(dst + i) = *(const uint32_t *)(src + i);
    else
        for (size_t i = 0; i < n; i++) dst[i] = src[i];
    __sync_synchronize();
}

static void mmio_ddr_read(device *d, uint32_t a, void *data, size_t n) {
    volatile uint8_t *src = ((mmio *)d->state)->ddr + (a - DDR_LOW);
    uint8_t *dst = data;
    if (((uintptr_t)dst | (uintptr_t)src | n) % 4 == 0)
        for (size_t i = 0; i < n; i += 4) *(uint32_t *)(dst + i) = *(volatile uint32_t *)(src + i);
    else
        for (size_t i = 0; i < n; i++) dst[i] = src[i];
}

static void mmio_advance(device *d, uint32_t cycles) { (void)d; (void)cycles; }

device *device_mmio(void) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return NULL; }
    mmio *m = calloc(1, sizeof *m);
    m->regs = mmap(0, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, LWH2F_BASE);
    m->ddr = mmap(0, DDR_HIGH - DDR_LOW, PROT_READ | PROT_WRITE, MAP_SHARED, fd, DDR_LOW);
    if (m->regs == MAP_FAILED || m->ddr == MAP_FAILED) { perror("mmap"); return NULL; }
    device *d = calloc(1, sizeof *d);
    d->write32 = mmio_write32;
    d->read32 = mmio_read32;
    d->ddr_write = mmio_ddr_write;
    d->ddr_read = mmio_ddr_read;
    d->advance = mmio_advance;
    d->ddr_low = DDR_LOW;
    d->ddr_high = DDR_HIGH;
    d->state = m;
    return d;
}
