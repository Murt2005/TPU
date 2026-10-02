// systolic_data_setup's pins, for its driver and monitor
interface systolic_data_setup_if #(parameter int ARRAY_SIZE = 4, parameter int DATA_WIDTH = 8) (input logic clk);
    logic                                         reset;
    logic signed [ARRAY_SIZE-1:0][DATA_WIDTH-1:0] row_in;
    logic                                         row_valid_in;
    logic signed [ARRAY_SIZE-1:0][DATA_WIDTH-1:0] skewed_row_out;
    logic        [ARRAY_SIZE-1:0]                 skewed_valid_out;
endinterface
