// the array's inputs (before the systolic data setup) and outputs, for its driver and monitor
interface mmu_if #(parameter int ARRAY_SIZE = 4) (input logic clk);
    logic                                       reset;
    logic signed [ARRAY_SIZE-1:0][8:0]          row_in;          // {weight flip, activation} per lane
    logic                                       row_valid_in;
    logic                                       weight_valid_in;
    logic        [$clog2(ARRAY_SIZE)-1:0]       weight_row_select_in;
    logic signed [ARRAY_SIZE-1:0][7:0]          weight_in;
    logic signed [ARRAY_SIZE-1:0][31:0]         partial_sum_out;
    logic        [ARRAY_SIZE-1:0]               partial_sum_valid_out;
endinterface
