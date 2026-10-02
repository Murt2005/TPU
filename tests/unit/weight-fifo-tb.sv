`timescale 1ns / 1ps

// weight_fifo: two slots filled a row at a time and drained whole, in order; a slot
// taken this cycle can be refilled this cycle
module weight_fifo_tb;
    `include "check.svh"

    localparam int N = 4;
    logic clk = 1'b0, reset = 1'b1;
    logic                  fill_ready_out, fill_slot_next_out, fill_advance_in = 1'b0;
    logic                  fill_write_enable_in = 1'b0, fill_slot_in = 1'b0;
    logic [7:0]            fill_row_in = '0;
    logic [N*8-1:0]        fill_data_in = '0;
    logic [N-1:0][N*8-1:0] tile_out;
    logic                  tile_full_out, tile_take_in = 1'b0;

    weight_fifo #(.ARRAY_SIZE(N)) dut (.*);

    always #5 clk = ~clk;
    task automatic tick(); @(posedge clk); #1; endtask

    function automatic logic [N*8-1:0] row_of(int t, int r); return (N*8)'(32'h01010101 * (16 * t + r)); endfunction

    // WT's pattern: advance as the last row issues, rows land one cycle later
    task automatic fill_tile(int t);
        logic slot;
        slot = fill_slot_next_out;
        for (int r = 0; r < N; r++) begin
            fill_write_enable_in = 1'b1; fill_slot_in = slot; fill_row_in = 8'(r); fill_data_in = row_of(t, r);
            fill_advance_in = r == N - 1;
            tick();
        end
        fill_write_enable_in = 1'b0; fill_advance_in = 1'b0;
    endtask

    initial begin
        tick(); tick(); reset = 1'b0;

        `TEST("empty after reset")
        `CHECK(!tile_full_out && fill_ready_out && !fill_slot_next_out, "flags")

        `TEST("a tile is full once its last row lands")
        fill_tile(0);
        `CHECK(tile_full_out, "full")
        for (int r = 0; r < N; r++) `CHECK_EQ(tile_out[r], row_of(0, r), $sformatf("row %0d", r))
        `CHECK(fill_slot_next_out && fill_ready_out, "the other slot is next, and free")

        `TEST("both slots full: no more room, the oldest tile stays at the head")
        fill_tile(1);
        `CHECK(!fill_ready_out, "no free slot")
        `CHECK_EQ(tile_out[0], row_of(0, 0), "tile 0 still at the head")

        `TEST("the slot being taken is free in the same cycle")
        tile_take_in = 1'b1; #1;
        `CHECK(fill_ready_out, "refill allowed during the take")
        tick(); tile_take_in = 1'b0;
        `CHECK(tile_full_out, "tile 1 is now the head")
        for (int r = 0; r < N; r++) `CHECK_EQ(tile_out[r], row_of(1, r), $sformatf("tile 1 row %0d", r))

        `TEST("tiles drain in fill order across wrap-around")
        fill_tile(2);
        tile_take_in = 1'b1; tick(); tile_take_in = 1'b0;
        `CHECK_EQ(tile_out[N-1], row_of(2, N - 1), "tile 2 follows tile 1")
        tile_take_in = 1'b1; tick(); tile_take_in = 1'b0;
        `CHECK(!tile_full_out && fill_ready_out, "empty again")

        tb_done();
    end
endmodule
