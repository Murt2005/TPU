# Platform Designer component: tpu_top as an Avalon-MM slave for the HPS
# lightweight bridge. word-addressed, 15 registers, fixed read latency 1,
# waitrequest only on writes into a full FIFO (see rtl/peripherals/host-bridge.sv).
# m0: the core's DDR3 master (rtl/control/memory-arbiter.sv): burst reads for MATMUL
# wsrc=1 and RD_DDR_UB, single-beat writes for ACTIVATE dst=DDR
package require -exact qsys 16.1

set_module_property NAME tpu
set_module_property VERSION 1.0
set_module_property DISPLAY_NAME "TPU"
set_module_property GROUP "TPU"
set_module_property EDITABLE false

set rtl ../../../../rtl
set files [list \
    $rtl/common/tpu-pkg.sv $rtl/common/fifo.sv $rtl/common/block-fifo.sv $rtl/common/profiler.sv $rtl/datapath/systolic-data-setup.sv $rtl/datapath/pe.sv $rtl/datapath/mmu.sv $rtl/datapath/weight-fifo.sv $rtl/datapath/unified-buffer.sv $rtl/datapath/accumulator.sv $rtl/datapath/bias.sv $rtl/datapath/activation.sv $rtl/control/dispatch.sv $rtl/control/load-engine.sv $rtl/control/weight-engine.sv $rtl/control/matmul-engine.sv $rtl/control/activate-engine.sv $rtl/control/ddr-reader.sv $rtl/control/ddr-writer.sv $rtl/control/memory-arbiter.sv $rtl/tpu-core.sv $rtl/peripherals/host-bridge.sv \
    ../../top/tpu-top.sv]

add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL tpu_top
foreach f $files {
    add_fileset_file [file tail $f] SYSTEM_VERILOG PATH $f
}

# the DDR3 port's width, set by the Makefile (DDR_BITS): 256 bits feed four weight rows
# a cycle (a tile every 2 cycles at m = 1), 128 bits two
set ddr_bits [expr {[info exists ::env(TPU_DDR_BITS)] ? $::env(TPU_DDR_BITS) : 128}]
set lanes [expr {$ddr_bits == 256 ? 4 : 2}]
foreach {name value} [list ARRAY_SIZE 8 WMEM_ROWS 8192 UB_DEPTH 16384 ACC_DEPTH 1024 PARAMETER_DEPTH 256 \
                          WEIGHT_LANES $lanes DDR_BEAT_BITS $ddr_bits] {
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

add_interface m0 avalon start
set_interface_property m0 associatedClock clock
set_interface_property m0 associatedReset reset
set_interface_property m0 addressUnits SYMBOLS
set_interface_property m0 burstOnBurstBoundariesOnly false
set_interface_property m0 linewrapBursts false
set_interface_property m0 doStreamReads false
add_interface_port m0 avm_address address Output 32
add_interface_port m0 avm_read read Output 1
add_interface_port m0 avm_write write Output 1
add_interface_port m0 avm_burstcount burstcount Output 8
add_interface_port m0 avm_writedata writedata Output $ddr_bits
add_interface_port m0 avm_byteenable byteenable Output [expr {$ddr_bits / 8}]
add_interface_port m0 avm_waitrequest waitrequest Input 1
add_interface_port m0 avm_readdata readdata Input $ddr_bits
add_interface_port m0 avm_readdatavalid readdatavalid Input 1
