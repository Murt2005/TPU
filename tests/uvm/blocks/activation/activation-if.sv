// activation's pins, for its driver and monitor
interface activation_if #(parameter int ARRAY_SIZE = 4) (input logic clk);
    logic                     reset;
    logic [ARRAY_SIZE*32-1:0] row_in;
    logic                     relu_enable_in;
    logic [ARRAY_SIZE*32-1:0] row_out;
    logic                     multiply_enable_in;
    logic [ARRAY_SIZE*32-1:0] multiply_row_in;
    logic [ARRAY_SIZE*32-1:0] quantization_row_in;
    logic [ARRAY_SIZE*8-1:0]  quantized_row_out;
endinterface
