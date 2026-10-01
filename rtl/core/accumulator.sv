`timescale 1ns / 1ps

// Accumulates the partial sums outputted from the mmu
module accumulator #(
    parameter int NUM_COLS   = 2,
    parameter int PSUM_WIDTH = 16,
    parameter int FIFO_DEPTH = 4,
    parameter int ROWS_PER_PASS = 2
) (
    input  logic clk,
    input  logic reset,

    input  logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] in_partial_sum,
    input  logic        [NUM_COLS-1:0]                 in_partial_sum_valid,

    input  logic tile_first,
    input  logic tile_last,

    output logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] out_row,
    output logic                         out_row_valid,

    output logic                         pass_done,

    // Backpressure-free for now... consumer must accept the row when
    // out_row_valid is high); status flags are exposed for future use
    output logic any_fifo_full
);

    localparam int ROW_IDX_W = (ROWS_PER_PASS > 1) ? $clog2(ROWS_PER_PASS) : 1;

    logic                          fifo_empty [NUM_COLS];
    logic                          fifo_full  [NUM_COLS];
    logic signed [PSUM_WIDTH-1:0]  fifo_rd_data [NUM_COLS];
    logic                          pop_row;

    logic all_fifos_have_data;
    always_comb begin
        all_fifos_have_data = 1'b1;
        for (int c = 0; c < NUM_COLS; c++) begin
            all_fifos_have_data &= !fifo_empty[c];
        end
    end

    assign pop_row = all_fifos_have_data;

    always_comb begin
        any_fifo_full = 1'b0;
        for (int c = 0; c < NUM_COLS; c++) begin
            any_fifo_full |= fifo_full[c];
        end
    end

    genvar gc;
    generate
        for (gc = 0; gc < NUM_COLS; gc++) begin : col_fifo
            fifo #(
                .WIDTH(PSUM_WIDTH),
                .DEPTH(FIFO_DEPTH)
            ) u_fifo (
                .clk     (clk),
                .reset   (reset),
                .write_enable   (in_partial_sum_valid[gc]),
                .write_data (in_partial_sum[gc]),
                .read_enable   (pop_row),
                .read_data (fifo_rd_data[gc]),
                .full    (fifo_full[gc]),
                .empty   (fifo_empty[gc])
            );
        end
    endgenerate

    logic signed [PSUM_WIDTH-1:0] psum_reg [ROWS_PER_PASS][NUM_COLS];
    logic [ROW_IDX_W-1:0]         row_idx;

    always_ff @(posedge clk) begin
        if (reset) begin
            out_row_valid <= 1'b0;
            pass_done     <= 1'b0;
            row_idx       <= '0;
            for (int r = 0; r < ROWS_PER_PASS; r++)
                for (int c = 0; c < NUM_COLS; c++)
                    psum_reg[r][c] <= '0;
            for (int c = 0; c < NUM_COLS; c++)
                out_row[c] <= '0;
        end else begin
            out_row_valid <= 1'b0;
            pass_done     <= 1'b0;
            if (pop_row) begin
                for (int c = 0; c < NUM_COLS; c++) begin
                    if (tile_first) begin
                        psum_reg[row_idx][c] <= fifo_rd_data[c];
                        if (tile_last) out_row[c] <= fifo_rd_data[c];
                    end else begin
                        psum_reg[row_idx][c] <= psum_reg[row_idx][c] + fifo_rd_data[c];
                        if (tile_last) out_row[c] <= psum_reg[row_idx][c] + fifo_rd_data[c];
                    end
                end
                out_row_valid <= tile_last;

                if (row_idx == ROW_IDX_W'(ROWS_PER_PASS - 1)) begin
                    row_idx   <= '0;
                    pass_done <= 1'b1;
                end else begin
                    row_idx <= row_idx + 1'b1;
                end
            end
        end
    end

endmodule
