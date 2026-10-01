`timescale 1ns / 1ps

// matrix multiply unit (MMU)
module mmu #(
    parameter int ARRAY_ROWS = 2,
    parameter int NUM_COLS   = 2,
    parameter int DATA_WIDTH = 8,
    parameter int PSUM_WIDTH = 16,
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
        for (r = 0; r < ARRAY_ROWS; r++) begin : gen_act_row
            assign act_in[r][0]       = in_row[r];
            assign act_in_valid[r][0] = in_row_valid[r];
            for (c = 1; c < NUM_COLS; c++) begin : gen_act_col
                assign act_in[r][c]       = act_out[r][c-1];
                assign act_in_valid[r][c] = act_out_valid[r][c-1];
            end
        end

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

        if (USE_MAC16_PAIR != 0) begin : gen_pair_rows
            if (ARRAY_ROWS % 2 != 0) begin : gen_odd_rows_check
                $error("USE_MAC16_PAIR requires even ARRAY_ROWS (got %0d)", ARRAY_ROWS);
            end
            if (PSUM_WIDTH != 16) begin : gen_pair_width_check
                $error("USE_MAC16_PAIR requires PSUM_WIDTH=16 (got %0d)", PSUM_WIDTH);
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
                    pe #(.PSUM_WIDTH(PSUM_WIDTH)) pe_inst (
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
