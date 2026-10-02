# MNIST end to end on the DE1-SoC's ARM. `make data sim-bench` on the Mac;
# `make arm` in the Quartus VM (arm-linux-gnueabihf-gcc), then copy build/{mnist_tpu,
# model.bin,testset.bin} to the SD card's FAT partition
REPO   := ../../..
PY     ?= $(REPO)/.venv/bin/python
TB_ISA ?= $(abspath $(REPO)/sim/verilator/core_n8/tb_isa)
CFLAGS := -O2 -ffp-contract=off -Wall -Wextra

.PHONY: data arm sim sim-bench

data: build/model.bin
build/model.bin: make_data.py
	$(PY) make_data.py build

# -ffp-contract=off: no fused multiply-adds, so preprocessing rounds like numpy
arm: build/mnist_tpu
build/mnist_tpu: mnist-tpu.c
	arm-linux-gnueabihf-gcc $(CFLAGS) -static -s -o $@ $< -lm

sim: build/mnist_tpu_sim
build/mnist_tpu_sim: mnist-tpu.c
	$(CC) -DSIM $(CFLAGS) -o $@ $< -lm

# the whole flow against Verilator (make rtl-sim first): bit-exact, not timing
sim-bench: sim data
	TB_ISA=$(TB_ISA) build/mnist_tpu_sim bench build/model.bin build/testset.bin 200
