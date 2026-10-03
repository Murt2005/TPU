`timescale 1ns / 1ps

// weight FIFO: a ring of tile slots between WMEM (or DDR3) and the array. WT fills one
// slot FILL_ROWS rows at a time while MM streams others into the PEs' weight_next
// registers. with one row per cycle (FILL_ROWS = 1) two slots do: one filling, one
// streaming. MM streams a tile over N cycles whatever the rate, so at FILL_ROWS rows a
// cycle FILL_ROWS tiles stream at once and the ring needs FILL_ROWS + 1 slots. a slot
// MM releases refills the same cycle (its last row was read into MM's weight register
// that cycle), so windows never starve
module weight_fifo #(
    parameter int ARRAY_SIZE = 8,
    parameter int FILL_ROWS  = 1,                                         // rows WT writes per cycle
    parameter int SLOTS      = FILL_ROWS + 1,
    parameter int SLOT_WIDTH = SLOTS > 2 ? $clog2(SLOTS) : 1
) (
    input  logic                                               clk,
    input  logic                                               reset,
    output logic                                               fill_ready_out,       // the slot WT fills next is free
    output logic [SLOT_WIDTH-1:0]                              fill_slot_next_out,
    input  logic                                               fill_advance_in,      // WT issued that slot's last rows
    input  logic                                               fill_write_enable_in, // FILL_ROWS rows land per cycle
    input  logic [SLOT_WIDTH-1:0]                              fill_slot_in,
    input  logic [7:0]                                         fill_row_in,          // the first of them, a multiple of FILL_ROWS
    input  logic [FILL_ROWS*ARRAY_SIZE*8-1:0]                  fill_data_in,
    output logic [ARRAY_SIZE-1:0][ARRAY_SIZE*8-1:0]            tile_out,             // the oldest tile not released; row r = K index r
    output logic                                               tile_full_out,
    input  logic                                               tile_take_in,         // release the oldest
    output logic [SLOTS-1:0][ARRAY_SIZE-1:0][ARRAY_SIZE*8-1:0] slots_out,            // every slot, for MM's concurrent streams
    output logic [SLOTS-1:0]                                   slot_full_out,
    output logic [SLOT_WIDTH-1:0]                              drain_slot_out        // the oldest's slot
);
    initial begin
        if (ARRAY_SIZE % FILL_ROWS != 0) $fatal(1, "weight_fifo: FILL_ROWS=%0d must divide ARRAY_SIZE=%0d", FILL_ROWS, ARRAY_SIZE);
        if (SLOTS < 2) $fatal(1, "weight_fifo: SLOTS=%0d", SLOTS);
    end

    logic [SLOTS-1:0][ARRAY_SIZE-1:0][ARRAY_SIZE*8-1:0] slot;
    logic [SLOTS-1:0]                                   slot_full;
    logic [SLOT_WIDTH-1:0]                              fill_slot_index, drain_slot_index;

    function automatic logic [SLOT_WIDTH-1:0] next_slot(input logic [SLOT_WIDTH-1:0] index);
        return index == SLOT_WIDTH'(SLOTS - 1) ? '0 : index + SLOT_WIDTH'(1);
    endfunction

    assign fill_ready_out     = !slot_full[fill_slot_index] || (tile_take_in && drain_slot_index == fill_slot_index);
    assign fill_slot_next_out = fill_slot_index;
    assign tile_out           = slot[drain_slot_index];
    assign tile_full_out      = slot_full[drain_slot_index];
    assign slots_out          = slot;
    assign slot_full_out      = slot_full;
    assign drain_slot_out     = drain_slot_index;

    always_ff @(posedge clk) begin
        if (reset) begin
            slot             <= '0;
            slot_full        <= '0;
            fill_slot_index  <= '0;
            drain_slot_index <= '0;
        end else begin
            if (fill_advance_in)
                fill_slot_index <= next_slot(fill_slot_index);
            if (fill_write_enable_in) begin
                for (int k = 0; k < FILL_ROWS; k++)
                    slot[fill_slot_in][fill_row_in + 8'(k)] <= fill_data_in[ARRAY_SIZE*8*k +: ARRAY_SIZE*8];
                if (fill_row_in == 8'(ARRAY_SIZE - FILL_ROWS))
                    slot_full[fill_slot_in] <= 1'b1;
            end
            if (tile_take_in) begin
                slot_full[drain_slot_index] <= 1'b0;
                drain_slot_index            <= next_slot(drain_slot_index);
            end
        end
    end
endmodule
