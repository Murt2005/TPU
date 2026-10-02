`timescale 1ns / 1ps

// weight FIFO: a two-slot tile buffer between WMEM and the array. WT fills one slot
// a row at a time while MM drains the other into the PEs' weight_next registers. a slot
// MM releases refills the same cycle (its last row was read into MM's weight
// register that cycle), so N-cycle windows never starve
module weight_fifo #(
    parameter int ARRAY_SIZE = 8
) (
    input  logic                    clk,
    input  logic                    reset,

    output logic                    fill_ready,        // the slot WT fills next is free
    output logic                    fill_slot_next,
    input  logic                    fill_advance,      // WT issued that slot's last row

    input  logic                    fill_write_enable, // one row lands per cycle
    input  logic                    fill_slot,
    input  logic [7:0]              fill_row,
    input  logic [ARRAY_SIZE*8-1:0] fill_data,

    output logic [ARRAY_SIZE-1:0][ARRAY_SIZE*8-1:0] tile,          // the oldest full tile; row r = K index r
    output logic  tile_full,
    input  logic  take
);

    logic [ARRAY_SIZE-1:0] [ARRAY_SIZE*8-1:0] slot_0, slot_1;
    logic [1:0]                               slot_full;
    logic                                     fill_slot_index, drain_slot_index;

    assign fill_ready     = !slot_full[fill_slot_index] || (take && drain_slot_index == fill_slot_index);
    assign fill_slot_next = fill_slot_index;
    assign tile           = drain_slot_index ? slot_1 : slot_0;
    assign tile_full      = slot_full[drain_slot_index];

    always_ff @(posedge clk) begin
        if (reset) begin
            slot_0           <= '0;
            slot_1           <= '0;
            slot_full        <= '0;
            fill_slot_index  <= 1'b0;
            drain_slot_index <= 1'b0;
        end else begin
            if (fill_advance)
                fill_slot_index <= !fill_slot_index;
            if (fill_write_enable) begin
                if (fill_slot) slot_1[fill_row] <= fill_data;
                else           slot_0[fill_row] <= fill_data;
                if (fill_row == 8'(ARRAY_SIZE - 1))
                    slot_full[fill_slot] <= 1'b1;
            end
            if (take) begin
                slot_full[drain_slot_index] <= 1'b0;
                drain_slot_index            <= !drain_slot_index;
            end
        end
    end

endmodule
