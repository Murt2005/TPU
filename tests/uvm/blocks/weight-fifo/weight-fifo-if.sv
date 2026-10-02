// weight_fifo's pins, for its driver and monitor
interface weight_fifo_if #(parameter int ARRAY_SIZE = 4) (input logic clk);
    logic                                    reset;
    logic                                    fill_ready_out;
    logic                                    fill_slot_next_out;
    logic                                    fill_advance_in;
    logic                                    fill_write_enable_in;
    logic                                    fill_slot_in;
    logic [7:0]                              fill_row_in;
    logic [ARRAY_SIZE*8-1:0]                 fill_data_in;
    logic [ARRAY_SIZE-1:0][ARRAY_SIZE*8-1:0] tile_out;
    logic                                    tile_full_out;
    logic                                    tile_take_in;
endinterface
