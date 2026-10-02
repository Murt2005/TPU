# adds the tpu component to Terasic's rev H GHRD on the lightweight bridge at offset 0
# (0xFF200000), and hex_pio at 0x10100 (0xFF210100) for the HEX displays
# (decoded by top/hex-display.sv); both on clk_0 like everything else
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
save_system soc_system.qsys
