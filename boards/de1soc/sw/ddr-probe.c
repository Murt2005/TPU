/* ddr_probe's ARM side, through /dev/mem. no libc (a few KB, small enough to send
 * over the serial console). prints hex; boards/de1soc/sw/ddr-probe.py does the math
 *   ddr_probe peek <addr>...                      32-bit reads
 *   ddr_probe poke <addr> <value>                 a 32-bit write
 *   ddr_probe sum <addr> <bytes>                  sum of the 32-bit words, mod 2^32
 *   ddr_probe run <addr> <beats> <burst> <outstanding>
 *                                                 one probe run; prints its 15 registers
 *   ddr_probe load <mbytes>                       ARM memory traffic until killed
 * numbers are hex */

#define PROBE_BASE 0xFF240000u   /* lightweight bridge + 0x40000 */
#define PROBE_REGISTERS 15

static long sys6(long n, long a, long b, long c, long d, long e, long f) {
    register long r7 __asm__("r7") = n;
    register long r0 __asm__("r0") = a;
    register long r1 __asm__("r1") = b;
    register long r2 __asm__("r2") = c;
    register long r3 __asm__("r3") = d;
    register long r4 __asm__("r4") = e;
    register long r5 __asm__("r5") = f;
    __asm__ volatile("svc 0" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2), "r"(r3), "r"(r4), "r"(r5) : "memory");
    return r0;
}
#define SYS_WRITE 4
#define SYS_OPEN 5
#define SYS_MUNMAP 91
#define SYS_MMAP2 192

static unsigned hex(const char *s) {
    unsigned v = 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    for (; *s; s++) v = v * 16 + (unsigned)(*s <= '9' ? *s - '0' : (*s | 32) - 'a' + 10);
    return v;
}

static void put_words(const unsigned *v, int n) {
    char out[9 * PROBE_REGISTERS + 1], *o = out;
    for (int i = 0; i < n; i++) {
        for (int k = 28; k >= 0; k -= 4) *o++ = "0123456789abcdef"[(v[i] >> k) & 15];
        *o++ = i == n - 1 ? '\n' : ' ';
    }
    sys6(SYS_WRITE, 1, (long)out, o - out, 0, 0, 0);
}

static long mem_fd;

/* maps [address, address + bytes) of physical memory, page-rounded */
static volatile unsigned *map(unsigned address, unsigned bytes) {
    unsigned page = address & ~0xfffu;
    long p = sys6(SYS_MMAP2, 0, (long)(bytes + (address - page)), 3 /* RW */, 1 /* SHARED */, mem_fd, (long)(page >> 12));
    if ((unsigned long)p > 0xfffff000UL) return 0;
    return (volatile unsigned *)(p + (address - page));
}

int cmain(long *sp) {
    long argc = sp[0];
    char **argv = (char **)(sp + 1);
    if (argc < 2) return 2;
    mem_fd = sys6(SYS_OPEN, (long)"/dev/mem", 0x101002 /* O_RDWR|O_SYNC */, 0, 0, 0, 0);
    if (mem_fd < 0) return 1;
    char c = argv[1][0], c1 = argv[1][1];

    if (c == 'p' && c1 == 'e') {                                  /* peek */
        for (long i = 2; i < argc; i++) {
            unsigned a = hex(argv[i]);
            volatile unsigned *w = map(a, 4);
            if (!w) return 3;
            unsigned pair[2] = {a, *w};
            put_words(pair, 2);
        }
    } else if (c == 'p' && c1 == 'o' && argc == 4) {              /* poke */
        volatile unsigned *w = map(hex(argv[2]), 4);
        if (!w) return 3;
        *w = hex(argv[3]);
    } else if (c == 's' && argc == 4) {                           /* sum */
        unsigned a = hex(argv[2]), bytes = hex(argv[3]), sum = 0;
        volatile unsigned *w = map(a, bytes);
        if (!w) return 3;
        for (unsigned i = 0; i < bytes / 4; i++) sum += w[i];
        put_words(&sum, 1);
    } else if (c == 'r' && argc == 6) {                           /* run */
        volatile unsigned *r = map(PROBE_BASE, 64);
        if (!r) return 3;
        if (r[0] != 0xDD3B0001u) return 4;
        r[2] = hex(argv[2]); r[3] = hex(argv[3]); r[4] = hex(argv[4]); r[5] = hex(argv[5]);
        r[1] = 1;
        unsigned polls = 0;
        while (r[1] & 1)
            if (++polls == 50000000u) { r[1] = 2; break; }       /* a port in reset never answers */
        unsigned v[PROBE_REGISTERS];
        for (int i = 0; i < PROBE_REGISTERS; i++) v[i] = r[i];
        if (polls == 50000000u) v[1] = 0xdead;
        put_words(v, PROBE_REGISTERS);
    } else if (c == 'l' && argc == 3) {                           /* load */
        unsigned bytes = hex(argv[2]) << 20;
        long p = sys6(SYS_MMAP2, 0, bytes, 3, 0x22 /* PRIVATE|ANONYMOUS */, -1, 0);
        if ((unsigned long)p > 0xfffff000UL) return 3;
        volatile unsigned *w = (volatile unsigned *)p;
        for (unsigned pass = 0;; pass++)
            for (unsigned i = 0; i < bytes / 4; i += 8) w[i] += pass;   /* one word per 32-byte line */
    } else {
        return 2;
    }
    return 0;
}

__attribute__((naked, noreturn)) void _start(void) {
    __asm__ volatile("mov r0, sp\n bl cmain\n mov r7, #1\n svc 0\n");
}
