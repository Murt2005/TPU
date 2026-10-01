`timescale 1ns / 1ps

// bias-add unit
module bias #(
    parameter int NUM_COLS   = 2,
    parameter int PSUM_WIDTH = 16
) (
    input  logic clk,
    input  logic reset,

    input  logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] in_row,
    input  logic                         in_row_valid,

    input  logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] in_bias,

    output logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] out_row,
    output logic                         out_row_valid
);

    always_ff @(posedge clk) begin
        if (reset) begin
            out_row_valid <= 1'b0;
            for (int c = 0; c < NUM_COLS; c++) begin
                out_row[c] <= '0;
            end
        end else begin
            out_row_valid <= in_row_valid;
            if (in_row_valid) begin
                for (int c = 0; c < NUM_COLS; c++) begin
                    out_row[c] <= in_row[c] + in_bias[c];
                end
            end
        end
    end

endmodule
