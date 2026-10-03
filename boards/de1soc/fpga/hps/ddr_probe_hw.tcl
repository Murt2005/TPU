# Platform Designer component: ddr_probe (top/ddr-probe.sv), a burst-read master
# for the HPS's FPGA-to-SDRAM port with its registers on the lightweight bridge
package require -exact qsys 16.1

set_module_property NAME ddr_probe
set_module_property VERSION 1.0
set_module_property DISPLAY_NAME "DDR3 bandwidth probe"
set_module_property GROUP "TPU"
set_module_property EDITABLE false

add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL ddr_probe
add_fileset_file ddr-probe.sv SYSTEM_VERILOG PATH ../../top/ddr-probe.sv

# the port's width (the Makefile's DDR_BITS), as the TPU's
set ddr_bits [expr {[info exists ::env(TPU_DDR_BITS)] ? $::env(TPU_DDR_BITS) : 128}]
add_parameter BEAT_BITS INTEGER $ddr_bits
set_parameter_property BEAT_BITS HDL_PARAMETER true

add_interface clock clock end
add_interface_port clock clk clk Input 1

add_interface reset reset end
set_interface_property reset associatedClock clock
set_interface_property reset synchronousEdges DEASSERT
add_interface_port reset reset_n reset_n Input 1

add_interface s0 avalon end
set_interface_property s0 associatedClock clock
set_interface_property s0 associatedReset reset
set_interface_property s0 addressUnits WORDS
set_interface_property s0 readLatency 1
set_interface_property s0 maximumPendingReadTransactions 0
set_interface_property s0 readWaitTime 0
set_interface_property s0 writeWaitTime 0
add_interface_port s0 avs_address address Input 4
add_interface_port s0 avs_read read Input 1
add_interface_port s0 avs_readdata readdata Output 32
add_interface_port s0 avs_write write Input 1
add_interface_port s0 avs_writedata writedata Input 32

add_interface m0 avalon start
set_interface_property m0 associatedClock clock
set_interface_property m0 associatedReset reset
set_interface_property m0 addressUnits SYMBOLS
set_interface_property m0 burstOnBurstBoundariesOnly false
set_interface_property m0 linewrapBursts false
set_interface_property m0 doStreamReads false
add_interface_port m0 avm_address address Output 32
add_interface_port m0 avm_read read Output 1
add_interface_port m0 avm_burstcount burstcount Output 8
add_interface_port m0 avm_waitrequest waitrequest Input 1
add_interface_port m0 avm_readdata readdata Input $ddr_bits
add_interface_port m0 avm_readdatavalid readdatavalid Input 1
