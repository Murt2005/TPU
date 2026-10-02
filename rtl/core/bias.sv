`timescale 1ns / 1ps

// bias: per-column 32-bit add (wraps), the first step of ACTIVATE. combinational;
// the ACT engine registers the activation unit's output
module bias #(
    parameter int ARRAY_SIZE = 8
) (
    input  logic [ARRAY_SIZE*32-1:0] row_in,
    input  logic [ARRAY_SIZE*32-1:0] bias_row_in,
    input  logic                     bias_enable_in,
    output logic [ARRAY_SIZE*32-1:0] row_out
);

    always_comb
        for (int column = 0; column < ARRAY_SIZE; column++)
            row_out[32*column +: 32] = row_in[32*column +: 32] + (bias_enable_in ? bias_row_in[32*column +: 32] : 32'd0);

endmodule
