// bias's pins, for its driver and monitor (combinational; the clock only paces it)
interface bias_if #(parameter int ARRAY_SIZE = 4) (input logic clk);
    logic                     reset;
    logic [ARRAY_SIZE*32-1:0] row_in;
    logic [ARRAY_SIZE*32-1:0] bias_row_in;
    logic                     bias_enable_in;
    logic [ARRAY_SIZE*32-1:0] row_out;
endinterface
