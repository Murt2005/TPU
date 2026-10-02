`timescale 1ns / 1ps

// weight_fifo: two slots filled a row at a time and drained whole, in order; a slot
// taken this cycle can be refilled this cycle
module weight_fifo_tb;
    `include "check.svh"

    localparam int N = 4;
    logic clk = 1'b0, reset = 1'b1;
    logic fill_ready, fill_slot_next, fill_advance = 1'b0;
    logic fill_write_enable = 1'b0, fill_slot = 1'b0;
    logic [7:0] fill_row = '0;
    logic [N*8-1:0] fill_data = '0;
    logic [N-1:0][N*8-1:0] tile;
    logic tile_full, take = 1'b0;

    weight_fifo #(.ARRAY_SIZE(N)) dut (.*);

    always #5 clk = ~clk;
    task automatic tick(); @(posedge clk); #1; endtask

    function automatic logic [N*8-1:0] row_of(int t, int r); return (N*8)'(32'h01010101 * (16 * t + r)); endfunction

    // WT's pattern: advance as the last row issues, rows land one cycle later
    task automatic fill_tile(int t);
        logic slot;
        slot = fill_slot_next;
        for (int r = 0; r < N; r++) begin
            fill_write_enable = 1'b1; fill_slot = slot; fill_row = 8'(r); fill_data = row_of(t, r);
            fill_advance = r == N - 1;
            tick();
        end
        fill_write_enable = 1'b0; fill_advance = 1'b0;
    endtask

    initial begin
        tick(); tick(); reset = 1'b0;

        `TEST("empty after reset")
        `CHECK(!tile_full && fill_ready && !fill_slot_next, "flags")

        `TEST("a tile is full once its last row lands")
        fill_tile(0);
        `CHECK(tile_full, "full")
        for (int r = 0; r < N; r++) `CHECK_EQ(tile[r], row_of(0, r), $sformatf("row %0d", r))
        `CHECK(fill_slot_next && fill_ready, "the other slot is next, and free")

        `TEST("both slots full: no more room, the oldest tile stays at the head")
        fill_tile(1);
        `CHECK(!fill_ready, "no free slot")
        `CHECK_EQ(tile[0], row_of(0, 0), "tile 0 still at the head")

        `TEST("the slot being taken is free in the same cycle")
        take = 1'b1; #1;
        `CHECK(fill_ready, "refill allowed during the take")
        tick(); take = 1'b0;
        `CHECK(tile_full, "tile 1 is now the head")
        for (int r = 0; r < N; r++) `CHECK_EQ(tile[r], row_of(1, r), $sformatf("tile 1 row %0d", r))

        `TEST("tiles drain in fill order across wrap-around")
        fill_tile(2);
        take = 1'b1; tick(); take = 1'b0;
        `CHECK_EQ(tile[N-1], row_of(2, N - 1), "tile 2 follows tile 1")
        take = 1'b1; tick(); take = 1'b0;
        `CHECK(!tile_full && fill_ready, "empty again")

        tb_done();
    end
endmodule
