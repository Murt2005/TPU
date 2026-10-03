# qwen-run on the Mac (cores ref, sim, null) and, cross-compiled in the Quartus
# VM, on the DE1-SoC's ARM (cores mmio, null): make, make arm
SOURCES := qwen-run.c model.c core.c device.c tables.c
CFLAGS  := -O3 -Wall -Wextra -std=c11 -D_DEFAULT_SOURCE -D_POSIX_C_SOURCE=200809L

qwen-run: $(SOURCES) qwen.h
	cc $(CFLAGS) -o $@ $(SOURCES) -lm

# Cortex-A9: NEON, hard float; static, the board's userland is a 2014 image
qwen-run-arm: $(SOURCES) qwen.h
	arm-linux-gnueabihf-gcc $(CFLAGS) -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard -static -o $@ $(SOURCES) -lm

arm: qwen-run-arm

clean:
	rm -f qwen-run qwen-run-arm

.PHONY: arm clean
