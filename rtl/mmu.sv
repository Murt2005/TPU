`timescale 1ns / 1ps

// mmu
// ----
// Weight-stationary systolic array: an ARRAY_ROWS x NUM_COLS grid of `pe`
// instances, built with a generate block so the array size is a parameter
// bump, not a port-list rewrite (matches the pattern already used by
// weight_fifo.sv / accumulator.sv: array ports rather than individually
// named per-row/per-column signals).
//
// Data flow through the grid (unchanged from the original hardcoded 2x2):
//   - Activations enter on the LEFT edge (in_row[r]) and shift rightward
//     one PE per cycle, row r independent of the others.
//   - Weights enter on the TOP edge (in_col[c]) and shift downward one PE
//     per cycle during loading_phase, column c independent of the others.
//     capture_weight_col[c] is broadcast to every PE in column c -- exactly
//     as the original design broadcast capture_weight_col_0 to both pe00
//     and pe10 (the weight-loading contract in weight_fifo.sv depends on
//     this: bottom-row weights must be presented first so they're already
//     shifted into place by the time the top-row weights arrive).
//   - Partial sums enter the TOP edge at zero/invalid and accumulate
//     downward one PE per cycle; out_partial_sum[c]/out_partial_sum_valid[c]
//     is the BOTTOM edge of column c, i.e. the finished dot product.
//
// Boundary conditions (replacing the original's hardcoded 16'd0/1'b0 and
// unconnected ports):
//   - the top edge's incoming partial sum is '0/invalid for every column
//   - the last column's out_activation / last row's out_weight are left
//     unread -- same as the original's dangling pe01.out_activation /
//     pe10.out_weight etc.
//
// Each PE's in_*/out_* pair is split into its own array (act_in/act_out,
// weight_in/weight_out, psum_in/psum_out) rather than one shared network
// array indexed 0..N, because Icarus Verilog rejects an array that is
// partly driven by generate-instance port connections and partly by a
// procedural/continuous boundary assignment elsewhere -- even at disjoint
// indices, it treats the whole array as one multiply-driven object. Keeping
// "written by the generate block" and "written by boundary logic" as
// physically separate arrays sidesteps that; act_in[r][c]/weight_in[r][c]/
// psum_in[r][c] are wired from either the boundary input or the previous
// PE's *_out via the assigns below.
//
// DATA_WIDTH/PSUM_WIDTH are exposed for consistency with weight_fifo.sv /
// accumulator.sv's parameter lists, but `pe.sv` itself hardcodes 8-bit
// activation/weight and 16-bit partial-sum ports today -- changing these
// away from the defaults requires parameterizing pe.sv too (out of scope
// here; ARRAY_ROWS/NUM_COLS are the axes this rewrite actually enables).
module mmu #(
    parameter int ARRAY_ROWS = 2,
    parameter int NUM_COLS   = 2,
    parameter int DATA_WIDTH = 8,
    parameter int PSUM_WIDTH = 16,
    // 1 = build the grid from pe_pair (one hand-instantiated SB_MAC16 in
    // dual-8x8 mode per two row-adjacent PEs; halves the DSP count so 4x4
    // fits the UP5K's 8 blocks). Requires even ARRAY_ROWS. 0 = plain pe.sv
    // path (yosys -dsp inference or LUT multipliers), any shape.
    parameter int USE_MAC16_PAIR = 0
) (
    input logic clk,
    input logic reset,
    input logic loading_phase,

    input logic [NUM_COLS-1:0] capture_weight_col,

    input logic signed [ARRAY_ROWS-1:0][DATA_WIDTH-1:0] in_row,
    input logic        [ARRAY_ROWS-1:0]                 in_row_valid,

    input logic signed [NUM_COLS-1:0][DATA_WIDTH-1:0] in_col,
    input logic        [NUM_COLS-1:0]                 in_col_valid,

    output logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] out_partial_sum,
    output logic        [NUM_COLS-1:0]                 out_partial_sum_valid
);

    // Per-PE input/output nets, ARRAY_ROWS x NUM_COLS each. act_in/weight_in/
    // psum_in are driven only by the boundary `assign`s below; act_out/
    // weight_out/psum_out are driven only by the generate block's PE
    // instances -- see header comment for why they can't share one array.
    logic signed [DATA_WIDTH-1:0] act_in  [ARRAY_ROWS][NUM_COLS];
    logic                         act_in_valid [ARRAY_ROWS][NUM_COLS];
    logic signed [DATA_WIDTH-1:0] act_out [ARRAY_ROWS][NUM_COLS];
    logic                         act_out_valid [ARRAY_ROWS][NUM_COLS];

    logic signed [DATA_WIDTH-1:0] weight_in  [ARRAY_ROWS][NUM_COLS];
    logic                         weight_in_valid [ARRAY_ROWS][NUM_COLS];
    logic signed [DATA_WIDTH-1:0] weight_out [ARRAY_ROWS][NUM_COLS];
    logic                         weight_out_valid [ARRAY_ROWS][NUM_COLS];

    logic signed [PSUM_WIDTH-1:0] psum_in  [ARRAY_ROWS][NUM_COLS];
    logic                         psum_in_valid [ARRAY_ROWS][NUM_COLS];
    logic signed [PSUM_WIDTH-1:0] psum_out [ARRAY_ROWS][NUM_COLS];
    logic                         psum_out_valid [ARRAY_ROWS][NUM_COLS];

    genvar r, c;
    generate
        // Activation: row r's PE(r,0) reads the left-edge input; PE(r,c)
        // for c>0 reads PE(r,c-1)'s registered output.
        for (r = 0; r < ARRAY_ROWS; r++) begin : gen_act_row
            assign act_in[r][0]       = in_row[r];
            assign act_in_valid[r][0] = in_row_valid[r];
            for (c = 1; c < NUM_COLS; c++) begin : gen_act_col
                assign act_in[r][c]       = act_out[r][c-1];
                assign act_in_valid[r][c] = act_out_valid[r][c-1];
            end
        end

        // Weight + partial-sum: column c's PE(0,c) reads the top-edge
        // weight input and a zero/invalid partial sum; PE(r,c) for r>0
        // reads PE(r-1,c)'s registered outputs. Column c's finished dot
        // product is PE(ARRAY_ROWS-1,c)'s partial-sum output.
        for (c = 0; c < NUM_COLS; c++) begin : gen_col_boundary
            assign weight_in[0][c]       = in_col[c];
            assign weight_in_valid[0][c] = in_col_valid[c];
            assign psum_in[0][c]         = '0;
            assign psum_in_valid[0][c]   = 1'b0;
            for (r = 1; r < ARRAY_ROWS; r++) begin : gen_weight_psum_row
                assign weight_in[r][c]       = weight_out[r-1][c];
                assign weight_in_valid[r][c] = weight_out_valid[r-1][c];
                assign psum_in[r][c]         = psum_out[r-1][c];
                assign psum_in_valid[r][c]   = psum_out_valid[r-1][c];
            end
            assign out_partial_sum[c]       = psum_out[ARRAY_ROWS-1][c];
            assign out_partial_sum_valid[c] = psum_out_valid[ARRAY_ROWS-1][c];
        end

        // pe_pair exposes exactly two pe.sv port sets (_t = row r, _b =
        // row r+1), so the pair path wires into the very same net arrays
        // as two stacked pe instances — including the mid-pair hop where
        // the top half's registered psum leaves on psum_out[r][c] and
        // re-enters as psum_in[r+1][c] -> the DSP's D input.
        if (USE_MAC16_PAIR != 0) begin : gen_pair_rows
            if (ARRAY_ROWS % 2 != 0) begin : gen_odd_rows_check
                $error("USE_MAC16_PAIR requires even ARRAY_ROWS (got %0d)", ARRAY_ROWS);
            end
            for (r = 0; r < ARRAY_ROWS; r += 2) begin : gen_row
                for (c = 0; c < NUM_COLS; c++) begin : gen_col
                    pe_pair pe_pair_inst (
                        .clk(clk),
                        .reset(reset),
                        .loading_phase(loading_phase),
                        .capture_weight(capture_weight_col[c]),

                        .in_activation_t(act_in[r][c]),
                        .in_activation_valid_t(act_in_valid[r][c]),
                        .out_activation_t(act_out[r][c]),
                        .out_activation_valid_t(act_out_valid[r][c]),
                        .in_partial_sum_t(psum_in[r][c]),
                        .in_partial_sum_valid_t(psum_in_valid[r][c]),
                        .out_partial_sum_t(psum_out[r][c]),
                        .out_partial_sum_valid_t(psum_out_valid[r][c]),
                        .in_weight_t(weight_in[r][c]),
                        .in_weight_valid_t(weight_in_valid[r][c]),
                        .out_weight_t(weight_out[r][c]),
                        .out_weight_valid_t(weight_out_valid[r][c]),

                        .in_activation_b(act_in[r+1][c]),
                        .in_activation_valid_b(act_in_valid[r+1][c]),
                        .out_activation_b(act_out[r+1][c]),
                        .out_activation_valid_b(act_out_valid[r+1][c]),
                        .in_partial_sum_b(psum_in[r+1][c]),
                        .in_partial_sum_valid_b(psum_in_valid[r+1][c]),
                        .out_partial_sum_b(psum_out[r+1][c]),
                        .out_partial_sum_valid_b(psum_out_valid[r+1][c]),
                        .in_weight_b(weight_in[r+1][c]),
                        .in_weight_valid_b(weight_in_valid[r+1][c]),
                        .out_weight_b(weight_out[r+1][c]),
                        .out_weight_valid_b(weight_out_valid[r+1][c])
                    );
                end
            end
        end else begin : gen_pe_rows
            for (r = 0; r < ARRAY_ROWS; r++) begin : gen_row
                for (c = 0; c < NUM_COLS; c++) begin : gen_col
                    pe pe_inst (
                        .clk(clk),
                        .reset(reset),

                        .in_activation(act_in[r][c]),
                        .in_activation_valid(act_in_valid[r][c]),
                        .out_activation(act_out[r][c]),
                        .out_activation_valid(act_out_valid[r][c]),

                        .in_partial_sum(psum_in[r][c]),
                        .in_partial_sum_valid(psum_in_valid[r][c]),
                        .out_partial_sum(psum_out[r][c]),
                        .out_partial_sum_valid(psum_out_valid[r][c]),

                        .loading_phase(loading_phase),
                        .capture_weight(capture_weight_col[c]),
                        .in_weight(weight_in[r][c]),
                        .in_weight_valid(weight_in_valid[r][c]),
                        .out_weight(weight_out[r][c]),
                        .out_weight_valid(weight_out_valid[r][c])
                    );
                end
            end
        end
    endgenerate

endmodule
