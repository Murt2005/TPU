/* recv <path> <bytes>: copy exactly <bytes> (decimal) from stdin to <path>, in
 * blocks. for BoardConsole.upload on a raw tty: busybox dd bs=1 makes a system
 * call per byte and tops out near 6 KB/s, this keeps up with the console's line
 * rate. no libc: about 1 KB, small enough to send over the console itself */

static long sys3(long n, long a, long b, long c) {
    register long r7 __asm__("r7") = n;
    register long r0 __asm__("r0") = a;
    register long r1 __asm__("r1") = b;
    register long r2 __asm__("r2") = c;
    __asm__ volatile("svc 0" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2) : "memory");
    return r0;
}
#define SYS_READ 3
#define SYS_WRITE 4
#define SYS_OPEN 5
#define SYS_CLOSE 6
#define SYS_FSYNC 118

static char block[65536];

int cmain(long *sp) {
    if (sp[0] != 3) return 2;
    char **argv = (char **)(sp + 1);
    unsigned long left = 0;
    for (const char *s = argv[2]; *s >= '0' && *s <= '9'; s++) left = left * 10 + (unsigned)(*s - '0');
    long fd = sys3(SYS_OPEN, (long)argv[1], 01 | 0100 | 01000 /* O_WRONLY|O_CREAT|O_TRUNC */, 0755);
    if (fd < 0) return 1;
    while (left) {
        long k = sys3(SYS_READ, 0, (long)block, left < sizeof block ? (long)left : (long)sizeof block);
        if (k <= 0) return 3;
        for (long done = 0; done < k;) {
            long w = sys3(SYS_WRITE, fd, (long)block + done, k - done);
            if (w <= 0) return 4;
            done += w;
        }
        left -= (unsigned long)k;
    }
    sys3(SYS_FSYNC, fd, 0, 0);
    return sys3(SYS_CLOSE, fd, 0, 0) < 0;
}

__attribute__((naked, noreturn)) void _start(void) {
    __asm__ volatile("mov r0, sp\n bl cmain\n mov r7, #1\n svc 0\n");
}
