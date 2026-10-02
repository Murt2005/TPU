# adds the tpu component to Terasic's rev H GHRD on the lightweight bridge at offset 0
# (0xFF200000), and hex_pio at 0x10100 (0xFF210100) for the HEX displays
# (decoded by top/hex-display.sv); both on clk_0 like everything else. also one
# 128-bit FPGA-to-SDRAM port (f2h_sdram0), shared by the TPU's DDR3 master
# (MATMUL wsrc=1, RD_DDR_UB, ACTIVATE dst=DDR) and ddr_probe, the probe's
# registers at 0x40000 (0xFF240000). U-Boot leaves the port in reset: fpgaportrst
# (0xFFC25080) needs 0x133 for it (command 0, read 0-1, write 0-1)
package require -exact qsys 16.1
load_system soc_system.qsys
add_instance tpu_0 tpu 1.0
add_connection clk_0.clk tpu_0.clock
add_connection clk_0.clk_reset tpu_0.reset
add_connection hps_0.h2f_lw_axi_master tpu_0.s0
set_connection_parameter_value hps_0.h2f_lw_axi_master/tpu_0.s0 baseAddress 0x00000000
# 6 digits x 5-bit code; reset value = every digit blank (code 16)
add_instance hex_pio altera_avalon_pio
set_instance_parameter_value hex_pio width 32
set_instance_parameter_value hex_pio direction Output
set_instance_parameter_value hex_pio resetValue 554189328
add_connection clk_0.clk hex_pio.clk
add_connection clk_0.clk_reset hex_pio.reset
add_connection hps_0.h2f_lw_axi_master hex_pio.s1
set_connection_parameter_value hps_0.h2f_lw_axi_master/hex_pio.s1 baseAddress 0x00010100
add_interface hex_pio_external_connection conduit end
set_interface_property hex_pio_external_connection EXPORT_OF hex_pio.external_connection
set_instance_parameter_value hps_0 F2SDRAM_Type {{Avalon-MM Bidirectional}}
set_instance_parameter_value hps_0 F2SDRAM_Width {128}
add_connection clk_0.clk hps_0.f2h_sdram0_clock
add_instance ddr_probe_0 ddr_probe 1.0
add_connection clk_0.clk ddr_probe_0.clock
add_connection clk_0.clk_reset ddr_probe_0.reset
add_connection hps_0.h2f_lw_axi_master ddr_probe_0.s0
set_connection_parameter_value hps_0.h2f_lw_axi_master/ddr_probe_0.s0 baseAddress 0x00040000
add_connection ddr_probe_0.m0 hps_0.f2h_sdram0_data
set_connection_parameter_value ddr_probe_0.m0/hps_0.f2h_sdram0_data baseAddress 0x00000000
add_connection tpu_0.m0 hps_0.f2h_sdram0_data
set_connection_parameter_value tpu_0.m0/hps_0.f2h_sdram0_data baseAddress 0x00000000
save_system soc_system.qsys
