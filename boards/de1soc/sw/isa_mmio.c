/* register server for tpu_isa_top on the HPS lightweight bridge. speaks the
 * tb_isa protocol on stdin/stdout (header of 5 u32, then 'W' reg u32,
 * 'R' reg -> u32, 'Q'), so host/tpu/isa_device.py drives the board exactly as
 * it drives Verilator. when stdin is a tty (the serial console) it goes raw for
 * the session. runs as root: /dev/mem */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <termios.h>
#include <unistd.h>

#define LWH2F_BASE 0xFF200000u
#define SPAN       0x1000u

static int get(void *p, size_t n) {
    uint8_t *b = p;
    while (n) {
        ssize_t k = read(0, b, n);
        if (k <= 0) return 0;
        b += k;
        n -= (size_t)k;
    }
    return 1;
}

static void put(const void *p, size_t n) {
    const uint8_t *b = p;
    while (n) {
        ssize_t k = write(1, b, n);
        if (k <= 0) exit(3);
        b += k;
        n -= (size_t)k;
    }
}

int main(int argc, char **argv) {
    uint32_t offset = argc > 1 ? (uint32_t)strtoul(argv[1], 0, 0) : 0;
    /* N, WMEM_ROWS, UB_DEPTH, ACC_DEPTH, PARAM_DEPTH: the bitstream's build parameters */
    uint32_t params[5] = {8, 8192, 16384, 1024, 256};
    for (int i = 0; i < 5 && argc > 2 + i; i++) params[i] = (uint32_t)strtoul(argv[2 + i], 0, 0);

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }
    volatile uint32_t *r = mmap(0, SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, LWH2F_BASE + offset);
    if (r == MAP_FAILED) { perror("mmap"); return 1; }

    struct termios saved, raw;
    int tty = isatty(0) && tcgetattr(0, &saved) == 0;
    if (tty) {
        raw = saved;
        cfmakeraw(&raw);
        tcsetattr(0, TCSANOW, &raw);
    }

    put(params, sizeof params);
    for (;;) {
        uint8_t cmd, reg;
        if (!get(&cmd, 1) || cmd == 'Q') break;
        if (!get(&reg, 1) || reg > 15) break;
        if (cmd == 'W') {
            uint32_t v;
            if (!get(&v, 4)) break;
            r[reg] = v;                 /* waitrequest stalls the bus while a FIFO is full */
        } else if (cmd == 'R') {
            uint32_t v = r[reg];
            put(&v, 4);
        } else {
            break;
        }
    }
    if (tty) tcsetattr(0, TCSANOW, &saved);
    return 0;
}
