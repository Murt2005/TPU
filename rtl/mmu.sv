`timescale 1ns / 1ps

module mmu (
    input logic  clk,
    input logic reset,
    input logic pass_weight,
    input logic capture_weight_col0,
    input logic capture_weight_col1,

    input logic signed [7:0] row0_in,
    input logic signed [7:0] row1_in,

    input logic signed [7:0] col0_in,
    input logic signed [7:0] col1_in,

    output logic signed [15:0] partial_sum_out_0,
    output logic signed [15:0] partial_sum_out_1
);


    logic signed [7:0] pe00_01_activation, pe10_11_activation;
    logic signed [7:0] pe00_10_weight, pe01_11_weight;
    logic signed [15:0] pe00_10_partial_sum, pe01_11_partial_sum;

    pe pe00 (
        .clk(clk),
        .reset(reset),
        .in_activation(row0_in),
        .out_activation(pe00_01_activation),
        .in_partial_sum(16'd0),
        .out_partial_sum(pe00_10_partial_sum),
        .pass_weight(pass_weight),
        .capture_weight(capture_weight_col0),
        .in_weight(col0_in),
        .out_weight(pe00_10_weight)
    );

    pe pe01 (
        .clk(clk),
        .reset(reset),
        .in_activation(pe00_01_activation),
        .out_activation(),
        .in_partial_sum(16'd0),
        .out_partial_sum(pe01_11_partial_sum),
        .pass_weight(pass_weight),
        .capture_weight(capture_weight_col1),
        .in_weight(col1_in),
        .out_weight(pe01_11_weight)
    );

    pe pe10 (
        .clk(clk),
        .reset(reset),
        .in_activation(row1_in),
        .out_activation(pe10_11_activation),
        .in_partial_sum(pe00_10_partial_sum),
        .out_partial_sum(partial_sum_out_0),
        .pass_weight(pass_weight),
        .capture_weight(capture_weight_col0),
        .in_weight(pe00_10_weight),
        .out_weight()
    );

    pe pe11 (
        .clk(clk),
        .reset(reset),
        .in_activation(pe10_11_activation),
        .out_activation(),
        .in_partial_sum(pe01_11_partial_sum),
        .out_partial_sum(partial_sum_out_1),
        .pass_weight(pass_weight),
        .capture_weight(capture_weight_col1),
        .in_weight(pe01_11_weight),
        .out_weight()
    );
endmodule
