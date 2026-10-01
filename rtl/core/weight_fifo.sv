`timescale 1ns / 1ps

// weight FIFO: a two-slot tile buffer between WMEM and the array. WT fills one slot
// a row at a time while MM drains the other into the PEs' w_next registers. a slot
// MM releases refills the same cycle (its last row was read into MM's weight
// register that cycle), so N-cycle windows never starve
module weight_fifo #(
    parameter int N = 8
) (
    input  logic                  clk,
    input  logic                  reset,

    output logic                  fill_ready,    // the slot WT fills next is free
    output logic                  fill_slot_next,
    input  logic                  fill_advance,  // WT issued that slot's last row

    input  logic                  fill_we,       // one row lands per cycle
    input  logic                  fill_slot,
    input  logic [7:0]            fill_row,
    input  logic [N*8-1:0]        fill_data,

    output logic [N-1:0][N*8-1:0] tile,          // the oldest full tile; row r = K index r
    output logic                  tile_full,
    input  logic                  take
);

    logic [N-1:0][N*8-1:0] buf0, buf1;
    logic [1:0]  full;
    logic        wr_idx, rd_idx;

    assign fill_ready     = !full[wr_idx] || (take && rd_idx == wr_idx);
    assign fill_slot_next = wr_idx;
    assign tile           = rd_idx ? buf1 : buf0;
    assign tile_full      = full[rd_idx];

    always_ff @(posedge clk) begin
        if (reset) begin
            buf0   <= '0;
            buf1   <= '0;
            full   <= '0;
            wr_idx <= 1'b0;
            rd_idx <= 1'b0;
        end else begin
            if (fill_advance)
                wr_idx <= !wr_idx;
            if (fill_we) begin
                if (fill_slot) buf1[fill_row] <= fill_data;
                else           buf0[fill_row] <= fill_data;
                if (fill_row == 8'(N - 1))
                    full[fill_slot] <= 1'b1;
            end
            if (take) begin
                full[rd_idx] <= 1'b0;
                rd_idx       <= !rd_idx;
            end
        end
    end

endmodule
