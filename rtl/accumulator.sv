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
// a raw accumulated row and a pulse saying that row is valid.
//
// Tile accumulation (K-dim tiling)
// ---------------------------------
// A real matmul with K > ARRAY_ROWS has to be split into multiple
// weight-stationary passes through the array, one per ARRAY_ROWS-sized
// K-slice, with the partial sums from every pass summed together before
// bias/activation ever see them -- exactly what the TPUv1 paper's
// accumulator RAM does. This module holds that running sum itself, in a
// persistent psum_reg[ARRAY_ROWS][NUM_COLS] register array that survives
// across separate invocations (separate RUN commands from the sequencer):
//
//   tile_first=1: overwrite psum_reg with this pass's reassembled row
//                 (starts a new K-reduction)
//   tile_first=0: psum_reg += this pass's reassembled row (continue
//                 accumulating an existing K-reduction)
//   tile_last=1:  additionally forward the (now-final) psum_reg value to
//                 out_row/out_row_valid, so bias/activation execute
//   tile_last=0:  psum_reg is updated but nothing is forwarded downstream --
//                 bias/activation never fire for a non-final tile pass
//
// tile_first/tile_last must be held stable by the caller for the whole pass
// (all ARRAY_ROWS row-completions of that invocation). A single-shot 2x2
// matmul (this module's only use before tiling existed) is just
// tile_first=1, tile_last=1 every time, which reduces to the original
// always-forward behavior.
//
// pass_done pulses once per pass (every ARRAY_ROWS row-completions),
// regardless of tile_first/tile_last, so a caller has a completion signal
// to act on even when out_row_valid never fires (mid-K-reduction passes).
module accumulator #(
    parameter int NUM_COLS   = 2,
    parameter int PSUM_WIDTH = 16,
    parameter int FIFO_DEPTH = 4,
    parameter int ARRAY_ROWS = 2
) (
    input  logic clk,
    input  logic reset,

    // One partial-sum input + valid strobe per MMU output column.
    input  logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] in_partial_sum,
    input  logic        [NUM_COLS-1:0]                 in_partial_sum_valid,

    // Tile-accumulation control -- see header comment. Must stay stable for
    // the whole pass (all ARRAY_ROWS row-completions).
    input  logic tile_first,
    input  logic tile_last,

    // Output: one full row, valid for exactly one cycle when tile_last=1
    // and all columns' FIFOs have produced a matching entry.
    output logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] out_row,
    output logic                         out_row_valid,

    // Pulses for exactly one cycle once every ARRAY_ROWS rows of this pass
    // have been folded into psum_reg, regardless of tile_last.
    output logic                         pass_done,

    // Backpressure-free for now (consumer must accept the row when
    // out_row_valid is high); status flags exposed for future use.
    output logic any_fifo_full
);

    localparam int ROW_IDX_W = (ARRAY_ROWS > 1) ? $clog2(ARRAY_ROWS) : 1;

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

    // Persistent per-row running sum, survives across separate passes.
    logic signed [PSUM_WIDTH-1:0] psum_reg [ARRAY_ROWS][NUM_COLS];
    logic [ROW_IDX_W-1:0]         row_idx;

    always_ff @(posedge clk) begin
        if (reset) begin
            out_row_valid <= 1'b0;
            pass_done     <= 1'b0;
            row_idx       <= '0;
            for (int r = 0; r < ARRAY_ROWS; r++)
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

                if (row_idx == ROW_IDX_W'(ARRAY_ROWS - 1)) begin
                    row_idx   <= '0;
                    pass_done <= 1'b1;
                end else begin
                    row_idx <= row_idx + 1'b1;
                end
            end
        end
    end

endmodule
