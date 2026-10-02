// the FIFO's pins, for its driver and monitor
interface fifo_if #(parameter int WIDTH = 16) (input logic clk);
    logic                    reset;
    logic                    write_enable_in;
    logic signed [WIDTH-1:0] write_data_in;
    logic                    read_enable_in;
    logic signed [WIDTH-1:0] read_data_out;
    logic                    full_out;
    logic                    empty_out;
endinterface
