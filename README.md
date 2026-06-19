# Reverse engineering Google's TPUv1

## Files:
rtl/
  mmu.sv - 2x2 systolic array
  pe.sv - processing element
tests/
  pe_tb.sv - pe testbench

## Simulation Workflow
Link and compile files:
- iverilog -g2012 -o output_name input1.sv input2.sv ... testbench.sv
Run the compiled simulation file:
- vvp output_name.vvp
