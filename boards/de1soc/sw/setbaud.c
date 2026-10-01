/* setbaud <rate>: set the controlling tty to any baud rate through termios2/BOTHER,
 * for rates the board's busybox stty doesn't know. no libc: about 1 KB, small
 * enough to send over the serial console itself */
#include <asm/ioctls.h>
#include <asm/termbits.h>

static long sys3(long n, long a, long b, long c) {
    register long r7 __asm__("r7") = n;
    register long r0 __asm__("r0") = a;
    register long r1 __asm__("r1") = b;
    register long r2 __asm__("r2") = c;
    __asm__ volatile("svc 0" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2) : "memory");
    return r0;
}

int cmain(long *sp) {
    if (sp[0] < 2) return 2;
    const char *s = ((char **)(sp + 1))[1];
    unsigned rate = 0;
    while (*s >= '0' && *s <= '9') rate = rate * 10 + (unsigned)(*s++ - '0');
    struct termios2 t;
    if (sys3(54 /* ioctl */, 0, TCGETS2, (long)&t) < 0) return 1;
    t.c_cflag &= ~CBAUD;
    t.c_cflag |= BOTHER;
    t.c_ispeed = t.c_ospeed = rate;
    t.c_cflag &= ~(CBAUD << IBSHIFT);
    t.c_cflag |= BOTHER << IBSHIFT;
    return sys3(54, 0, TCSETSW2, (long)&t) < 0;
}

__attribute__((naked, noreturn)) void _start(void) {
    __asm__ volatile("mov r0, sp\n bl cmain\n mov r7, #1\n svc 0\n");
}
