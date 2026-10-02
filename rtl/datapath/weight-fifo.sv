`timescale 1ns / 1ps

// weight FIFO: a two-slot tile buffer between WMEM and the array. WT fills one slot
// a row at a time while MM drains the other into the PEs' weight_next registers. a slot
// MM releases refills the same cycle (its last row was read into MM's weight
// register that cycle), so N-cycle windows never starve
module weight_fifo #(
    parameter int ARRAY_SIZE = 8
) (
    input  logic                                    clk,
    input  logic                                    reset,

    output logic                                    fill_ready_out,       // the slot WT fills next is free
    output logic                                    fill_slot_next_out,
    input  logic                                    fill_advance_in,      // WT issued that slot's last row

    input  logic                                    fill_write_enable_in, // one row lands per cycle
    input  logic                                    fill_slot_in,
    input  logic [7:0]                              fill_row_in,
    input  logic [ARRAY_SIZE*8-1:0]                 fill_data_in,

    output logic [ARRAY_SIZE-1:0][ARRAY_SIZE*8-1:0] tile_out,             // the oldest full tile; row r = K index r
    output logic                                    tile_full_out,
    input  logic                                    tile_take_in
);

    logic [ARRAY_SIZE-1:0] [ARRAY_SIZE*8-1:0] slot_0, slot_1;
    logic [1:0]                               slot_full;
    logic                                     fill_slot_index, drain_slot_index;

    assign fill_ready_out     = !slot_full[fill_slot_index] || (tile_take_in && drain_slot_index == fill_slot_index);
    assign fill_slot_next_out = fill_slot_index;
    assign tile_out           = drain_slot_index ? slot_1 : slot_0;
    assign tile_full_out      = slot_full[drain_slot_index];

    always_ff @(posedge clk) begin
        if (reset) begin
            slot_0           <= '0;
            slot_1           <= '0;
            slot_full        <= '0;
            fill_slot_index  <= 1'b0;
            drain_slot_index <= 1'b0;
        end else begin
            if (fill_advance_in)
                fill_slot_index <= !fill_slot_index;
            if (fill_write_enable_in) begin
                if (fill_slot_in) slot_1[fill_row_in] <= fill_data_in;
                else              slot_0[fill_row_in] <= fill_data_in;
                if (fill_row_in == 8'(ARRAY_SIZE - 1))
                    slot_full[fill_slot_in] <= 1'b1;
            end
            if (tile_take_in) begin
                slot_full[drain_slot_index] <= 1'b0;
                drain_slot_index            <= !drain_slot_index;
            end
        end
    end

endmodule
