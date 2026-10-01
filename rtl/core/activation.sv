`timescale 1ns / 1ps

// activation unit: ReLU or identity, then the requantizer to int8. the requantizer is
// three registered stages under the ACT engine's control (this ReLU output, the
// multiply, the round): in one cycle the path missed 50 MHz on the Cyclone V by 4 ns
module activation #(
    parameter int N = 8
) (
    input  logic            clk,
    input  logic            reset,

    input  logic [N*32-1:0] in_row,      // biased
    input  logic            relu,
    output logic [N*32-1:0] out_row,

    input  logic            mul_en,      // stage 2: multiply mul_in by the M0s
    input  logic [N*32-1:0] mul_in,
    input  logic [N*32-1:0] quant_row,   // {shift[29:24], M0[23:0]} per column; held across stages
    output logic [N*8-1:0]  q_row        // stage 3: round, shift, clamp
);

    // saturate to 27 bits, multiply by M0 (27x25, one DSP each)
    function automatic logic signed [51:0] rq_mul(input logic signed [31:0] v, input logic [23:0] m0);
        logic signed [26:0] v27;
        v27 = (v > 32'sd67108863) ? 27'sd67108863 : (v < -32'sd67108864) ? -27'sd67108864 : v[26:0];
        return v27 * $signed({1'b0, m0});
    endfunction

    // add half, arithmetic shift, clamp to int8
    function automatic logic [7:0] rq_round(input logic signed [51:0] p, input logic [5:0] shift);
        logic signed [63:0] prod, rounded;
        prod = 64'(p);
        rounded = (shift == 6'd0) ? prod : (prod + (64'sd1 <<< (shift - 6'd1))) >>> shift;
        return (rounded > 64'sd127) ? 8'sd127 : (rounded < -64'sd128) ? 8'h80 : rounded[7:0];
    endfunction

    always_comb
        for (int c = 0; c < N; c++)
            out_row[32*c +: 32] = (relu && $signed(in_row[32*c +: 32]) < 0) ? 32'd0 : in_row[32*c +: 32];

    logic signed [N-1:0][51:0] prod_row;
    always_ff @(posedge clk) begin
        if (reset)
            prod_row <= '0;
        else if (mul_en)
            for (int c = 0; c < N; c++)
                prod_row[c] <= rq_mul(mul_in[32*c +: 32], quant_row[32*c +: 24]);
    end

    always_comb
        for (int c = 0; c < N; c++)
            q_row[8*c +: 8] = rq_round(prod_row[c], quant_row[32*c+24 +: 6]);

endmodule
