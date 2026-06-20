`timescale 1ns / 1ps

// Accumulator for a 2x2 weight-stationary MMU.
//
// Instantiates one weight_fifo per MMU output column. Each column's
// out_partial_sum is written into its FIFO on that column's valid
// pulse. This is required because the systolic array's output columns
// are skewed in time relative to each other (column j finishes (N-1-j)
// cycles after column 0 for the same logical row), so there is no shared
// "row valid" signal coming out of the MMU itself.
//
// The accumulator reassembles rows by popping one entry from every column
// FIFO together, the moment all column FIFOs are simultaneously non-empty.
// This streams a completed row to the bias unit as soon as it exists,
// rather than waiting for the whole output matrix -- minimizing latency
// and keeping FIFO depth at O(rows in flight) instead of O(N^2).
//
// This module does not know about bias or activation, it only produces
// a raw accumulated row and a pulse saying that row is valid
module accumulator #(
    parameter int NUM_COLS  = 2,
    parameter int PSUM_WIDTH = 16,
    parameter int FIFO_DEPTH = 4
) (
    input  logic clk,
    input  logic reset,

    // One partial-sum input + valid strobe per MMU output column.
    input  logic signed [PSUM_WIDTH-1:0] in_partial_sum [NUM_COLS],
    input  logic                         in_partial_sum_valid [NUM_COLS],

    // Output: one full row, valid for exactly one cycle when all
    // columns' FIFOs have produced a matching entry.
    output logic signed [PSUM_WIDTH-1:0] out_row [NUM_COLS],
    output logic                         out_row_valid,

    // Backpressure-free for now (consumer must accept the row when
    // out_row_valid is high); status flags exposed for future use.
    output logic any_fifo_full
);

    logic                          fifo_empty [NUM_COLS];
    logic                          fifo_full  [NUM_COLS];
    logic signed [PSUM_WIDTH-1:0]  fifo_rd_data [NUM_COLS];
    logic                          pop_row;

    // A row is ready exactly when every column FIFO is non-empty.
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

    genvar c;
    generate
        for (c = 0; c < NUM_COLS; c++) begin : col_fifo
            fifo #(
                .WIDTH(PSUM_WIDTH),
                .DEPTH(FIFO_DEPTH)
            ) u_fifo (
                .clk     (clk),
                .reset   (reset),
                .write_enable   (in_partial_sum_valid[c]),
                .write_data (in_partial_sum[c]),
                .read_enable   (pop_row),
                .read_data (fifo_rd_data[c]),
                .full    (fifo_full[c]),
                .empty   (fifo_empty[c])
            );
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (reset) begin
            out_row_valid <= 1'b0;
            for (int c = 0; c < NUM_COLS; c++) begin
                out_row[c] <= '0;
            end
        end else begin
            out_row_valid <= pop_row;
            if (pop_row) begin
                for (int c = 0; c < NUM_COLS; c++) begin
                    out_row[c] <= fifo_rd_data[c];
                end
            end
        end
    end

endmodule
