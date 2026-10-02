`timescale 1ns / 1ps

// N x N grid of pe. activations enter row r at column 0 already skewed by r;
// the row-select weight bus is skewed here, column c by c cycles, so a tile's
// weight row lands in each column exactly as far ahead of its flip
module mmu #(
    parameter int ARRAY_SIZE = 8
) (
    input  logic  clk,
    input  logic  reset,

    input  logic signed [ARRAY_SIZE-1:0][7:0]  activation,
    input  logic [ARRAY_SIZE-1:0]         activation_weight_flip,
    input  logic [ARRAY_SIZE-1:0]         activation_valid,

    input  logic                          weight_valid,
    input  logic [$clog2(ARRAY_SIZE)-1:0] weight_row,
    input  logic signed [ARRAY_SIZE-1:0][7:0]  weight_data,

    output logic signed [ARRAY_SIZE-1:0][31:0] partial_sum,
    output logic [ARRAY_SIZE-1:0] partial_sum_valid
);

    localparam int ROW_SELECT_WIDTH = $clog2(ARRAY_SIZE);

    // per-column weight bus after the column skew
    logic              column_weight_valid [ARRAY_SIZE];
    logic [ROW_SELECT_WIDTH-1:0]     column_weight_row   [ARRAY_SIZE];
    logic signed [7:0] column_weight_data  [ARRAY_SIZE];

    genvar row, column;
    generate
        for (column = 0; column < ARRAY_SIZE; column++) begin : g_weight_skew
            if (column == 0) begin : g_direct
                assign column_weight_valid[column] = weight_valid;
                assign column_weight_row[column]   = weight_row;
                assign column_weight_data[column]  = weight_data[column];
            end else begin : g_delay
                logic              delayed_weight_valid [column];
                logic [ROW_SELECT_WIDTH-1:0]     delayed_weight_row [column];
                logic signed [7:0] delayed_weight_data [column];
                always_ff @(posedge clk) begin
                    if (reset) begin
                        for (int stage = 0; stage < column; stage++) delayed_weight_valid[stage] <= 1'b0;
                    end else begin
                        delayed_weight_valid[0] <= weight_valid;
                        for (int stage = 1; stage < column; stage++) delayed_weight_valid[stage] <= delayed_weight_valid[stage-1];
                    end
                    delayed_weight_row[0]  <= weight_row;
                    delayed_weight_data[0] <= weight_data[column];
                    for (int stage = 1; stage < column; stage++) begin
                        delayed_weight_row[stage]  <= delayed_weight_row[stage-1];
                        delayed_weight_data[stage] <= delayed_weight_data[stage-1];
                    end
                end
                assign column_weight_valid[column] = delayed_weight_valid[column-1];
                assign column_weight_row[column]   = delayed_weight_row[column-1];
                assign column_weight_data[column]  = delayed_weight_data[column-1];
            end
        end

        for (row = 0; row < ARRAY_SIZE; row++) begin : g_row
            logic signed [7:0]  row_activation  [ARRAY_SIZE+1];
            logic               row_weight_flip [ARRAY_SIZE+1];
            logic               row_valid       [ARRAY_SIZE+1];
            assign row_activation[0]  = activation[row];
            assign row_weight_flip[0] = activation_weight_flip[row];
            assign row_valid[0]       = activation_valid[row];
            for (column = 0; column < ARRAY_SIZE; column++) begin : g_column
                logic signed [31:0] cell_partial_sum;
                logic               cell_partial_sum_valid;
                logic signed [31:0] cell_partial_sum_in;
                logic               cell_partial_sum_valid_in;
                if (row == 0) begin : g_top
                    assign cell_partial_sum_in       = '0;
                    assign cell_partial_sum_valid_in = 1'b1;
                end else begin : g_middle
                    assign cell_partial_sum_in       = g_row[row-1].g_column[column].cell_partial_sum;
                    assign cell_partial_sum_valid_in = g_row[row-1].g_column[column].cell_partial_sum_valid;
                end
                pe u_pe (
                    .clk(clk), .reset(reset),
                    .activation_in(row_activation[column]), .activation_valid_in(row_valid[column]), .weight_flip_in(row_weight_flip[column]),
                    .partial_sum_in(cell_partial_sum_in), .partial_sum_valid_in(cell_partial_sum_valid_in),
                    .weight_in(column_weight_data[column]),
                    .weight_valid_in(column_weight_valid[column] && column_weight_row[column] == ROW_SELECT_WIDTH'(row)),
                    .activation_out(row_activation[column+1]), .activation_valid_out(row_valid[column+1]), .weight_flip_out(row_weight_flip[column+1]),
                    .partial_sum_out(cell_partial_sum), .partial_sum_valid_out(cell_partial_sum_valid));
                if (row == ARRAY_SIZE - 1) begin : g_output
                    assign partial_sum[column]       = cell_partial_sum;
                    assign partial_sum_valid[column] = cell_partial_sum_valid;
                end
            end
        end
    endgenerate

endmodule
