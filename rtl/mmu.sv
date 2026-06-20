`timescale 1ns / 1ps

module mmu (
    input logic  clk,
    input logic reset,
    input logic loading_phase,
    input logic capture_weight_col_0,
    input logic capture_weight_col_1,

    input logic signed [7:0] in_row_0,
    input logic signed [7:0] in_row_1,

    input logic signed [7:0] in_col_0,
    input logic signed [7:0] in_col_1,

    output logic signed [15:0] out_partial_sum_0,
    output logic signed [15:0] out_partial_sum_1
);

    // Internal signals between PEs
    logic signed [7:0] pe_00_to_01_activation, pe_10_to_11_activation;
    logic signed [7:0] pe_00_to_10_weight, pe_01_to_11_weight;
    logic signed [15:0] pe_00_to_10_partial_sum, pe_01_to_11_partial_sum;

    pe pe00 (
        .clk(clk),
        .reset(reset),
        .in_activation(in_row_0),
        .out_activation(pe_00_to_01_activation),
        .in_partial_sum(16'd0),
        .out_partial_sum(pe_00_to_10_partial_sum),
        .loading_phase(loading_phase),
        .capture_weight(capture_weight_col_0),
        .in_weight(in_col_0),
        .out_weight(pe_00_to_10_weight)
    );

    pe pe01 (
        .clk(clk),
        .reset(reset),
        .in_activation(pe_00_to_01_activation),
        .out_activation(),
        .in_partial_sum(16'd0),
        .out_partial_sum(pe_01_to_11_partial_sum),
        .loading_phase(loading_phase),
        .capture_weight(capture_weight_col_1),
        .in_weight(in_col_1),
        .out_weight(pe_01_to_11_weight)
    );

    pe pe10 (
        .clk(clk),
        .reset(reset),
        .in_activation(in_row_1),
        .out_activation(pe_10_to_11_activation),
        .in_partial_sum(pe_00_to_10_partial_sum),
        .out_partial_sum(out_partial_sum_0),
        .loading_phase(loading_phase),
        .capture_weight(capture_weight_col_0),
        .in_weight(pe_00_to_10_weight),
        .out_weight()
    );

    pe pe11 (
        .clk(clk),
        .reset(reset),
        .in_activation(pe_10_to_11_activation),
        .out_activation(),
        .in_partial_sum(pe_01_to_11_partial_sum),
        .out_partial_sum(out_partial_sum_1),
        .loading_phase(loading_phase),
        .capture_weight(capture_weight_col_1),
        .in_weight(pe_01_to_11_weight),
        .out_weight()
    );
endmodule
