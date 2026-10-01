# DE1-SoC bitstream: Quartus on x86-64 Linux, around a GHRD-based project (see README.md)

# TODO: set to your GHRD-based Quartus project's names
PROJECT  ?= soc_system
REVISION ?= $(PROJECT)

QUARTUS_SH  := quartus_sh
QUARTUS_MAP := quartus_map
QUARTUS_FIT := quartus_fit
QUARTUS_ASM := quartus_asm
QUARTUS_STA := quartus_sta
QUARTUS_CPF := quartus_cpf

OUT     := output_files
SOF     := $(OUT)/$(REVISION).sof
RBF     := $(OUT)/$(REVISION).rbf

.PHONY: all sof rbf sta clean

all: rbf

sof:
	$(QUARTUS_SH) --flow compile $(PROJECT) -c $(REVISION)

$(SOF): sof

# .rbf is what the HPS loads
rbf: $(SOF)
	$(QUARTUS_CPF) -c -o bitstream_compression=on $(SOF) $(RBF)
	@echo "wrote $(RBF) — scp it to the board and load via u-boot / FPGA manager (see README.md)"

sta: $(SOF)
	$(QUARTUS_STA) $(PROJECT) -c $(REVISION)

clean:
	$(RM) -r db incremental_db $(OUT) *.qws *.rpt *.summary *.done \
	         *.pin *.jdi *.sld *.qarlog c5_pin_model_dump.txt
