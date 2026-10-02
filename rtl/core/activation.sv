`timescale 1ns / 1ps

// activation unit: ReLU or identity, then the requantizer to int8. the requantizer is
// three registered stages under the ACT engine's control (this ReLU output, the
// multiply, the round): in one cycle the path missed 50 MHz on the Cyclone V by 4 ns
module activation #(
    parameter int ARRAY_SIZE = 8
) (
    input  logic                     clk,
    input  logic                     reset,

    input  logic [ARRAY_SIZE*32-1:0] in_row,           // biased
    input  logic                     relu,
    output logic [ARRAY_SIZE*32-1:0] out_row,

    input  logic                     multiply_enable,  // stage 2: multiply mul_in by the M0s
    input  logic [ARRAY_SIZE*32-1:0] multiply_in,
    input  logic [ARRAY_SIZE*32-1:0] quantization_row, // {shift[29:24], M0[23:0]} per column; held across stages
    output logic [ARRAY_SIZE*8-1:0]  quantized_row     // stage 3: round, shift, clamp
);

    // saturate to 27 bits, multiply by M0 (27x25, one DSP each)
    function automatic logic signed [51:0] requantize_multiply(input logic signed [31:0] value, input logic [23:0] multiplier);
        logic signed [26:0] value_27_bit;
        value_27_bit = (value > 32'sd67108863) ? 27'sd67108863 : (value < -32'sd67108864) ? -27'sd67108864 : value[26:0];
        return value_27_bit * $signed({1'b0, multiplier});
    endfunction

    // add half, arithmetic shift, clamp to int8
    function automatic logic [7:0] requantize_round(input logic signed [51:0] product, input logic [5:0] shift);
        logic signed [63:0] product_wide, rounded;
        product_wide = 64'(product);
        rounded = (shift == 6'd0) ? product_wide : (product_wide + (64'sd1 <<< (shift - 6'd1))) >>> shift;
        return (rounded > 64'sd127) ? 8'sd127 : (rounded < -64'sd128) ? 8'h80 : rounded[7:0];
    endfunction

    always_comb
        for (int column = 0; column < ARRAY_SIZE; column++)
            out_row[32*column +: 32] = (relu && $signed(in_row[32*column +: 32]) < 0) ? 32'd0 : in_row[32*column +: 32];

    logic signed [ARRAY_SIZE-1:0][51:0] product_row;
    always_ff @(posedge clk) begin
        if (reset)
            product_row <= '0;
        else if (multiply_enable)
            for (int column = 0; column < ARRAY_SIZE; column++)
                product_row[column] <= requantize_multiply(multiply_in[32*column +: 32], quantization_row[32*column +: 24]);
    end

    always_comb
        for (int column = 0; column < ARRAY_SIZE; column++)
            quantized_row[8*column +: 8] = requantize_round(product_row[column], quantization_row[32*column+24 +: 6]);

endmodule
