# DE1-SoC FPGA-only self-test. `make rom` runs on the Mac (needs the repo venv and
# the MNIST model); `make` runs where Quartus is (the x86 Linux VM)
REPO    := ../../../..
PROJECT := tpu_selftest
OUT     := output_files
SOF     := $(OUT)/$(PROJECT).sof
RBF     := $(OUT)/$(PROJECT).rbf

.PHONY: all rom sof rbf sta clean

all: rbf

rom:
	cd $(REPO) && $(MAKE) --no-print-directory selftest-rom N=8

$(SOF): isa_selftest.hex $(PROJECT).qsf $(PROJECT).sdc $(wildcard $(REPO)/rtl/core/*.sv) \
        $(wildcard ../../top/*.sv) $(REPO)/rtl/peripherals/host_bridge.sv
	quartus_sh --flow compile $(PROJECT) -c $(PROJECT)

sof: $(SOF)

# uncompressed: what openFPGALoader loads over JTAG
rbf: $(SOF)
	quartus_cpf -c $(SOF) $(RBF)

isa_selftest.hex:
	@echo "isa_selftest.hex missing: run 'make rom' on the Mac first" && false

sta: $(SOF)
	quartus_sta $(PROJECT) -c $(PROJECT)

clean:
	$(RM) -r db incremental_db $(OUT) *.qws *.rpt *.summary *.done *.pin *.jdi *.sld \
	         *.qarlog c5_pin_model_dump.txt
