# adds tpu_isa to Terasic's rev H GHRD on the lightweight bridge at offset 0
# (0xFF200000), clocked and reset with everything else on clk_0
package require -exact qsys 16.1
load_system soc_system.qsys
add_instance tpu_isa_0 tpu_isa 1.0
add_connection clk_0.clk tpu_isa_0.clock
add_connection clk_0.clk_reset tpu_isa_0.reset
add_connection hps_0.h2f_lw_axi_master tpu_isa_0.s0
set_connection_parameter_value hps_0.h2f_lw_axi_master/tpu_isa_0.s0 baseAddress 0x00000000
save_system soc_system.qsys
