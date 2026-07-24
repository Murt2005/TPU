## ============================================================================
##  tpu_top_hps build for the DE1-SoC (Cyclone V 5CSEMA5F31C6N)
##
##  SCAFFOLDING — run on x86-64 Linux with Quartus Prime Lite (no macOS build
##  exists; see README.md for the Mac workflow). This wraps the Quartus
##  command-line flow around a project built on Terasic's DE1-SoC GHRD (which
##  supplies the HPS + h2f_lw bridge + DDR3 pins). Set PROJECT/REVISION to match
##  that project, then:
##
##    make            Compile (map -> fit -> asm) and produce the .rbf
##    make sof         Compile up to the .sof bitstream
##    make rbf         Convert the .sof to a HPS-loadable .rbf
##    make sta         Timing analysis (checks the 50 MHz constraint)
##    make clean       Remove Quartus build output
##
##  Programming is done from the board's HPS, not from here — see README.md.
## ============================================================================

# TODO: set these to your GHRD-based Quartus project's names.
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

# Full compile. (quartus_sh --flow compile runs analysis/synthesis, fit,
# assembler and timing in one go against the project's settings.)
sof:
	$(QUARTUS_SH) --flow compile $(PROJECT) -c $(REVISION)

$(SOF): sof

# HPS-loadable raw bitstream. bitstream_compression keeps the .rbf small.
rbf: $(SOF)
	$(QUARTUS_CPF) -c -o bitstream_compression=on $(SOF) $(RBF)
	@echo "wrote $(RBF) — scp it to the board and load via u-boot / FPGA manager (see README.md)"

sta: $(SOF)
	$(QUARTUS_STA) $(PROJECT) -c $(REVISION)

clean:
	$(RM) -r db incremental_db $(OUT) *.qws *.rpt *.summary *.done \
	         *.pin *.jdi *.sld *.qarlog c5_pin_model_dump.txt
