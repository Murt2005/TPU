# DE1-SoC with the HPS: Terasic's rev H GHRD + the TPU on the lightweight bridge
# at 0xFF200000. Terasic's files are extracted into build/ (not tracked); only the
# component, the qsys edit and this flow live in the repo. run inside the Quartus
# VM (see README.md); ARM programs build with arm-linux-gnueabihf-gcc there too
CD_ZIP ?= $(HOME)/Downloads/DE1-SoC_v.6.0.0_HWrevH_SystemCD.zip
QUARTUS_BIN ?= $(HOME)/intelFPGA_lite/23.1std/quartus
export PATH := $(QUARTUS_BIN)/bin:$(QUARTUS_BIN)/sopc_builder/bin:$(PATH)

HERE  := $(abspath .)
GHRD  := build/ghrd
SOF   := $(GHRD)/output_files/soc_system.sof
RBF   := build/soc_system.rbf
MMIO  := build/isa_mmio

.PHONY: all ghrd qsys sof rbf mmio setbaud clean

all: rbf mmio setbaud

$(GHRD)/stamp-tpu:
	rm -rf $(GHRD) build/_cd && mkdir -p build/_cd
	cd build/_cd && unzip -q "$(CD_ZIP)" "Demonstrations/SOC_FPGA/de1_soc_GHRD/*"
	mv build/_cd/Demonstrations/SOC_FPGA/de1_soc_GHRD $(GHRD) && rm -rf build/_cd
	cd $(GHRD) && qsys-script --script=$(HERE)/add-tpu.tcl --search-path="$(HERE),$$"
	python3 patch_top.py $(GHRD)/ghrd_top.v
	printf '\nset_global_assignment -name SYSTEMVERILOG_FILE $(HERE)/../../top/hex-display.sv\n' >> $(GHRD)/soc_system.qsf
	# pre-generated qip instead of QSYS_FILE, so the compile needn't find our component;
	# parallel helpers deadlock under Rosetta; pe.sv's checks are sim-only
	cd $(GHRD) && sed -i 's#^set_global_assignment -name QSYS_FILE soc_system.qsys#set_global_assignment -name QIP_FILE soc_system/synthesis/soc_system.qip#' soc_system.qsf
	# Terasic's qsf has no trailing newline: every append starts with one
	printf '\nset_global_assignment -name NUM_PARALLEL_PROCESSORS 1\nset_global_assignment -name VERILOG_MACRO "SYNTHESIS=1"\n' >> $(GHRD)/soc_system.qsf
	touch $@

ghrd: $(GHRD)/stamp-tpu

qsys: ghrd
	cd $(GHRD) && qsys-generate soc_system.qsys --synthesis=VERILOG --search-path="$(HERE),ip/**/*,$$"

$(SOF): ghrd ../../top/hex-display.sv $(wildcard ../../../../rtl/*.sv ../../../../rtl/*/*.sv) ../../top/tpu-top.sv tpu_hw.tcl
	$(MAKE) qsys
	cd $(GHRD) && quartus_sh --flow compile soc_system

sof: $(SOF)

# uncompressed, like Terasic's: U-Boot loads it in FPPx16 (MSEL = 00000)
$(RBF): $(SOF)
	quartus_cpf -c $(SOF) $@

rbf: $(RBF)

$(MMIO): ../../sw/isa-mmio.c
	arm-linux-gnueabihf-gcc -Os -static -s -Wall -Wextra -o $@ $<

mmio: $(MMIO)

# console baud beyond busybox stty's 921600 (1562500 for the demo); no libc, 636 bytes
build/setbaud: ../../sw/setbaud.c
	arm-linux-gnueabihf-gcc -Os -static -nostdlib -ffreestanding -fno-stack-protector -marm \
	    -Wall -Wl,--build-id=none -s -o $@ $<

setbaud: build/setbaud

clean:
	rm -rf build
