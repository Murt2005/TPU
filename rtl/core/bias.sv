`timescale 1ns / 1ps

// bias: per-column 32-bit add (wraps), the first step of ACTIVATE. combinational;
// the ACT engine registers the activation unit's output
module bias #(
    parameter int N = 8
) (
    input  logic [N*32-1:0] in_row,
    input  logic [N*32-1:0] bias_row,
    input  logic            enable,
    output logic [N*32-1:0] out_row
);

    always_comb
        for (int c = 0; c < N; c++)
            out_row[32*c +: 32] = in_row[32*c +: 32] + (enable ? bias_row[32*c +: 32] : 32'd0);

endmodule
