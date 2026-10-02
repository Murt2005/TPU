`timescale 1ns / 1ps

// systolic data setup: delays element i by i cycles
module systolic_data_setup #(
    parameter int ARRAY_SIZE = 8,
    parameter int DATA_WIDTH = 8
) (
    input  logic                                         clk,
    input  logic                                         reset,

    input  logic signed [ARRAY_SIZE-1:0][DATA_WIDTH-1:0] row_in,
    input  logic                                         row_valid_in,

    output logic signed [ARRAY_SIZE-1:0][DATA_WIDTH-1:0] skewed_row_out,   // lane i delayed i cycles
    output logic        [ARRAY_SIZE-1:0]                 skewed_valid_out
);

    genvar lane, stage;
    generate
        for (lane = 0; lane < ARRAY_SIZE; lane++) begin : g_lane
            if (lane == 0) begin : g_passthrough
                assign skewed_row_out[lane]   = row_in[lane];
                assign skewed_valid_out[lane] = row_valid_in;
            end else begin : g_delay_line
                logic signed [DATA_WIDTH-1:0] shift_data  [lane:0];
                logic                         shift_valid [lane:0];

                assign shift_data[0]  = row_in[lane];
                assign shift_valid[0] = row_valid_in;

                for (stage = 0; stage < lane; stage++) begin : g_stage
                    always_ff @(posedge clk) begin
                        if (reset) begin
                            shift_data[stage+1]  <= '0;
                            shift_valid[stage+1] <= 1'b0;
                        end else begin
                            shift_data[stage+1]  <= shift_data[stage];
                            shift_valid[stage+1] <= shift_valid[stage];
                        end
                    end
                end

                assign skewed_row_out[lane]   = shift_data[lane];
                assign skewed_valid_out[lane] = shift_valid[lane];
            end
        end
    endgenerate

endmodule
