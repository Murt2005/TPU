# Platform Designer component: tpu_isa_top as an Avalon-MM slave for the HPS
# lightweight bridge. word-addressed, 12 registers, fixed read latency 1,
# waitrequest only on writes into a full FIFO (see rtl/peripherals/isa_bridge.sv)
package require -exact qsys 16.1

set_module_property NAME tpu_isa
set_module_property VERSION 1.0
set_module_property DISPLAY_NAME "TPU instruction-stream core"
set_module_property GROUP "TPU"
set_module_property EDITABLE false

set rtl ../../../../rtl
set files [list \
    $rtl/isa/isa_pkg.sv $rtl/core/fifo.sv $rtl/core/systolic_data_setup.sv \
    $rtl/isa/isa_pe.sv $rtl/isa/isa_array.sv $rtl/isa/isa_dispatch.sv $rtl/isa/isa_ld.sv \
    $rtl/isa/isa_wt.sv $rtl/isa/isa_mm.sv $rtl/isa/isa_act.sv $rtl/isa/isa_core.sv \
    $rtl/peripherals/isa_bridge.sv ../../top/tpu_isa_top.sv]

add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL tpu_isa_top
foreach f $files {
    add_fileset_file [file tail $f] SYSTEM_VERILOG PATH $f
}

foreach {name value} {N 8 WMEM_ROWS 8192 UB_DEPTH 16384 ACC_DEPTH 1024 PARAM_DEPTH 256} {
    add_parameter $name INTEGER $value
    set_parameter_property $name HDL_PARAMETER true
}

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
add_interface_port s0 avs_waitrequest waitrequest Output 1
