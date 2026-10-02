// accumulator's pins, for its driver and monitor
interface accumulator_if #(parameter int ARRAY_SIZE = 4, parameter int ACC_ADDRESS_WIDTH = 4) (input logic clk);
    logic                                reset;
    logic signed [ARRAY_SIZE-1:0][31:0]  partial_sum_in;
    logic        [ARRAY_SIZE-1:0]        partial_sum_valid_in;
    logic                                tag_push_in;
    logic        [ACC_ADDRESS_WIDTH:0]   tag_in;
    logic                                row_written_out;
    logic        [ACC_ADDRESS_WIDTH-1:0] activate_read_address_in;
    logic                                activate_read_blocked_out;
    logic        [ARRAY_SIZE*32-1:0]     read_data_out;
endinterface
