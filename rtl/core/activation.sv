`timescale 1ns / 1ps

// ReLU activation unit
//
// Rectified Linear Unit (ReLU) function element-wise:
//
//   out[c] = max(0, in[c])
//
module activation #(
    parameter int NUM_COLS   = 2,
    parameter int PSUM_WIDTH = 16
) (
    input  logic clk,
    input  logic reset,

    // make the clamp optional for networks that have layers that aren't ReLU
    input  logic bypass,

    input  logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] in_row,
    input  logic                         in_row_valid,

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
                    out_row[c] <= (!bypass && $signed(in_row[c]) < 0) ? '0 : in_row[c];
                end
            end
        end
    end

endmodule
