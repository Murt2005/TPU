`timescale 1ns / 1ps

// Bias-add unit for a NUM_COLS-wide systolic array.
//
// Sits directly downstream of the accumulator: the accumulator produces one
// fully-reduced row at a time (out_row / out_row_valid), with no notion of
// bias or activation. This module's only job is to add a per-output-column
// bias term to that row, one cycle of registered latency, matching the
// latency style of every other module in this pipeline (pe, accumulator,
// systolic_data_setup's per-row delay, etc).
//
// This module has no awareness of where the bias values come from (a ROM,
// a register file, a DMA'd buffer) -- it just takes in_bias[NUM_COLS] as a
// flat array of stationary bias values and adds the matching column's bias
// to the matching column's accumulator output. A future bias_rom or
// weight_loader-style module is responsible for keeping in_bias valid and
// stable; this module samples it combinationally on the same cycle in_row
// is valid, so in_bias must already reflect the bias for the row currently
// being presented.
//
// This module also has no awareness of activation functions (ReLU, etc) --
// that is left to a downstream unit (e.g. bias_relu wraps bias + relu).
module bias #(
    parameter int NUM_COLS   = 2,
    parameter int PSUM_WIDTH = 16
) (
    input  logic clk,
    input  logic reset,

    // One fully-accumulated row in from the accumulator.
    input  logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] in_row,
    input  logic                         in_row_valid,

    // Stationary per-column bias values. Column c's bias is added to
    // in_row[c]. Sampled the same cycle in_row_valid is high.
    input  logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] in_bias,

    // Bias-added row out, valid for exactly one cycle, one cycle after
    // in_row_valid (registered, same latency convention as accumulator).
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
