// unified_buffer's pins, for its driver and monitor
interface unified_buffer_if #(parameter int ARRAY_SIZE = 4, parameter int ADDRESS_WIDTH = 4) (input logic clk);
    logic                     reset;   // the buffer has none; the driver waits on it
    logic                     load_write_enable_in;
    logic [ADDRESS_WIDTH-1:0] load_write_address_in;
    logic [ARRAY_SIZE*8-1:0]  load_write_data_in;
    logic                     activate_write_enable_in;
    logic [ADDRESS_WIDTH-1:0] activate_write_address_in;
    logic [ARRAY_SIZE*8-1:0]  activate_write_data_in;
    logic                     matmul_read_enable_in;
    logic [ADDRESS_WIDTH-1:0] matmul_read_address_in;
    logic [ADDRESS_WIDTH-1:0] activate_read_address_in;
    logic [ARRAY_SIZE*8-1:0]  read_data_out;
endinterface
