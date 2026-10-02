`timescale 1ns / 1ps

// bias: per-column 32-bit add (wraps), the first step of ACTIVATE. combinational;
// the ACT engine registers the activation unit's output
module bias #(
    parameter int ARRAY_SIZE = 8
) (
    input  logic [ARRAY_SIZE*32-1:0] in_row,
    input  logic [ARRAY_SIZE*32-1:0] bias_row,
    input  logic                     enable,
    output logic [ARRAY_SIZE*32-1:0] out_row
);

    always_comb
        for (int column = 0; column < ARRAY_SIZE; column++)
            out_row[32*column +: 32] = in_row[32*column +: 32] + (enable ? bias_row[32*column +: 32] : 32'd0);

endmodule
