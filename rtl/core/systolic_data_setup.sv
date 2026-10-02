`timescale 1ns / 1ps

// systolic data setup: delays element i by i cycles
module systolic_data_setup #(
    parameter int ARRAY_ROWS = 2,
    parameter int DATA_WIDTH = 8
) (
    input  logic  clk,
    input  logic  reset,

    input  logic signed [ARRAY_ROWS-1:0][DATA_WIDTH-1:0] UB_read_data,
    input  logic  UB_read_valid,

    output logic signed [ARRAY_ROWS-1:0][DATA_WIDTH-1:0] MMU_in_row,
    output logic [ARRAY_ROWS-1:0] MMU_in_valid
);

    genvar lane, stage;
    generate
        for (lane = 0; lane < ARRAY_ROWS; lane++) begin : g_lane
            if (lane == 0) begin : g_passthrough
                assign MMU_in_row[lane]   = UB_read_data[lane];
                assign MMU_in_valid[lane] = UB_read_valid;
            end else begin : g_delay_line
                logic signed [DATA_WIDTH-1:0] shift_data  [lane:0];
                logic                         shift_valid [lane:0];

                assign shift_data[0]  = UB_read_data[lane];
                assign shift_valid[0] = UB_read_valid;

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

                assign MMU_in_row[lane]   = shift_data[lane];
                assign MMU_in_valid[lane] = shift_valid[lane];
            end
        end
    endgenerate

endmodule
