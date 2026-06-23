`timescale 1ns / 1ps

// ReLU activation unit.
//
// Final pipeline stage in the TPU datapath, sitting immediately downstream
// of the bias unit.  The bias unit produces one fully-bias-corrected row per
// logical output row of the matrix multiplication; this module applies the
// Rectified Linear Unit (ReLU) function element-wise:
//
//   out[c] = max(0, in[c])
//
// This matches the TPUv1 architecture, where ReLU is the only supported
// non-linearity and is fused into the same pipeline stage as the bias add
// (here split into two composable modules for clarity and testability).
//
// Interface contract (identical to bias.sv):
//   - One cycle of registered latency: out_row_valid fires the cycle AFTER
//     in_row_valid is sampled.
//   - Exactly one out_row_valid pulse per in_row_valid pulse; no buffering.
//   - Reset forces out_row_valid low and clears out_row to zero.
//   - No stall / backpressure: consumer must accept the row the cycle it
//     is valid.
//
// Parameters:
//   NUM_COLS   - number of output columns (must match bias / accumulator).
//   PSUM_WIDTH - bit-width of each element; signed arithmetic throughout.
//                The clamp floor is always 0 regardless of PSUM_WIDTH.
module activation #(
    parameter int NUM_COLS   = 2,
    parameter int PSUM_WIDTH = 16
) (
    input  logic clk,
    input  logic reset,

    // Row from the bias unit.
    input  logic signed [PSUM_WIDTH-1:0] in_row  [NUM_COLS],
    input  logic                         in_row_valid,

    // ReLU-clamped row out.  Valid exactly one cycle after in_row_valid.
    output logic signed [PSUM_WIDTH-1:0] out_row [NUM_COLS],
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
                    // ReLU: Check the MSB (sign bit). 
                    // If 1 (negative), clamp to 0. If 0 (positive), pass through.
                    out_row[c] <= in_row[c][PSUM_WIDTH-1] ? '0 : in_row[c];
                end
            end
        end
    end

endmodule
