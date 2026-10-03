`timescale 1ns / 1ps

// Matrix Multiply Unit (MMU). the weight bus has WEIGHT_LANES lanes, each one row a
// cycle with its own row select; MM streams consecutive tiles on different lanes when
// they overlap, and a PE row takes the lane that addresses it (never two at once)
module mmu #(
    parameter int ARRAY_SIZE   = 8,
    parameter int WEIGHT_LANES = 1
) (
    input  logic                                                    clk,
    input  logic                                                    reset,

    input  logic signed [ARRAY_SIZE-1:0][7:0]                       activation_in,
    input  logic [ARRAY_SIZE-1:0]                                   activation_valid_in,
    input  logic [ARRAY_SIZE-1:0]                                   weight_flip_in,

    input  logic signed [WEIGHT_LANES-1:0][ARRAY_SIZE-1:0][7:0]     weight_in,
    input  logic        [WEIGHT_LANES-1:0]                          weight_valid_in,
    input  logic        [WEIGHT_LANES-1:0][$clog2(ARRAY_SIZE)-1:0]  weight_row_select_in,

    output logic signed [ARRAY_SIZE-1:0][31:0]                      partial_sum_out,
    output logic [ARRAY_SIZE-1:0]                                   partial_sum_valid_out
);

    localparam int ROW_SELECT_WIDTH = $clog2(ARRAY_SIZE);

    // per-column, per-lane weight bus after the column skew
    logic                        column_weight_valid      [ARRAY_SIZE][WEIGHT_LANES];
    logic [ROW_SELECT_WIDTH-1:0] column_weight_row_select [ARRAY_SIZE][WEIGHT_LANES];
    logic signed [7:0]           column_weight_data       [ARRAY_SIZE][WEIGHT_LANES];

    genvar row, column, lane;
    generate
        for (column = 0; column < ARRAY_SIZE; column++) begin : g_weight_skew
            for (lane = 0; lane < WEIGHT_LANES; lane++) begin : g_lane
                if (column == 0) begin : g_direct
                    assign column_weight_valid[column][lane]      = weight_valid_in[lane];
                    assign column_weight_row_select[column][lane] = weight_row_select_in[lane];
                    assign column_weight_data[column][lane]       = weight_in[lane][column];
                end else begin : g_delay
                    // registers, not a RAM-based shift register: Quartus made these 5 M10K blocks at 1% full
                    (* altera_attribute = "-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *) logic                        delayed_weight_valid      [column];
                    (* altera_attribute = "-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *) logic [ROW_SELECT_WIDTH-1:0] delayed_weight_row_select [column];
                    (* altera_attribute = "-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *) logic signed [7:0]           delayed_weight_data       [column];
                    always_ff @(posedge clk) begin
                        if (reset) begin
                            for (int stage = 0; stage < column; stage++) delayed_weight_valid[stage] <= 1'b0;
                        end else begin
                            delayed_weight_valid[0] <= weight_valid_in[lane];
                            for (int stage = 1; stage < column; stage++) delayed_weight_valid[stage] <= delayed_weight_valid[stage-1];
                        end
                        delayed_weight_row_select[0] <= weight_row_select_in[lane];
                        delayed_weight_data[0]       <= weight_in[lane][column];
                        for (int stage = 1; stage < column; stage++) begin
                            delayed_weight_row_select[stage] <= delayed_weight_row_select[stage-1];
                            delayed_weight_data[stage]       <= delayed_weight_data[stage-1];
                        end
                    end
                    assign column_weight_valid[column][lane]      = delayed_weight_valid[column-1];
                    assign column_weight_row_select[column][lane] = delayed_weight_row_select[column-1];
                    assign column_weight_data[column][lane]       = delayed_weight_data[column-1];
                end
            end
        end

        for (row = 0; row < ARRAY_SIZE; row++) begin : g_row
            logic signed [7:0]  row_activation       [ARRAY_SIZE+1];
            logic               row_activation_valid [ARRAY_SIZE+1];
            logic               row_weight_flip      [ARRAY_SIZE+1];
            assign row_activation[0]       = activation_in[row];
            assign row_activation_valid[0] = activation_valid_in[row];
            assign row_weight_flip[0]      = weight_flip_in[row];
            for (column = 0; column < ARRAY_SIZE; column++) begin : g_column
                // this PE's weight: from whichever lane addresses its row this cycle
                logic              cell_weight_valid;
                logic signed [7:0] cell_weight;
                always_comb begin
                    cell_weight_valid = 1'b0;
                    cell_weight       = '0;
                    for (int k = 0; k < WEIGHT_LANES; k++)
                        if (column_weight_valid[column][k] && column_weight_row_select[column][k] == ROW_SELECT_WIDTH'(row)) begin
                            cell_weight_valid = 1'b1;
                            cell_weight       = column_weight_data[column][k];
                        end
                end
                logic signed [31:0] cell_partial_sum_out;
                logic               cell_partial_sum_valid_out;
                logic signed [31:0] cell_partial_sum_in;
                logic               cell_partial_sum_valid_in;
                if (row == 0) begin : g_top
                    assign cell_partial_sum_in       = '0;
                    assign cell_partial_sum_valid_in = 1'b1;
                end else begin : g_middle
                    assign cell_partial_sum_in       = g_row[row-1].g_column[column].cell_partial_sum_out;
                    assign cell_partial_sum_valid_in = g_row[row-1].g_column[column].cell_partial_sum_valid_out;
                end
                pe u_pe (
                    .clk(clk),
                    .reset(reset),
                    .activation_in(row_activation[column]),
                    .activation_valid_in(row_activation_valid[column]),
                    .weight_flip_in(row_weight_flip[column]),
                    .partial_sum_in(cell_partial_sum_in),
                    .partial_sum_valid_in(cell_partial_sum_valid_in),
                    .weight_in(cell_weight),
                    .weight_valid_in(cell_weight_valid),
                    .activation_out(row_activation[column+1]),
                    .activation_valid_out(row_activation_valid[column+1]),
                    .weight_flip_out(row_weight_flip[column+1]),
                    .partial_sum_out(cell_partial_sum_out),
                    .partial_sum_valid_out(cell_partial_sum_valid_out));
                if (row == ARRAY_SIZE - 1) begin : g_output
                    assign partial_sum_out[column]       = cell_partial_sum_out;
                    assign partial_sum_valid_out[column] = cell_partial_sum_valid_out;
                end
            end
        end
    endgenerate

endmodule
