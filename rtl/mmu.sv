`timescale 1ns / 1ps

module mmu (
    input logic  clk,
    input logic reset,
    input logic loading_phase,
    input logic capture_weight_col_0,
    input logic capture_weight_col_1,

    input logic signed [7:0] in_row_0,
    input logic              in_row_0_valid,
    input logic signed [7:0] in_row_1,
    input logic              in_row_1_valid,

    input logic signed [7:0] in_col_0,
    input logic              in_col_0_valid,
    input logic signed [7:0] in_col_1,
    input logic              in_col_1_valid,

    output logic signed [15:0] out_partial_sum_0,
    output logic               out_partial_sum_0_valid,
    output logic signed [15:0] out_partial_sum_1,
    output logic               out_partial_sum_1_valid
);

    // Internal interconnect networks between PEs
    // Horizontal Activations
    logic signed [7:0] pe_00_to_01_activation;
    logic              pe_00_to_01_activation_valid;
    logic signed [7:0] pe_10_to_11_activation;
    logic              pe_10_to_11_actication_valid;

    // Vertical Weights
    logic signed [7:0] pe_00_to_10_weight;
    logic              pe_00_to_10_weight_valid;
    logic signed [7:0] pe_01_to_11_weight;
    logic              pe_01_to_11_weight_valid;

    // Vertical Partial Sums
    logic signed [15:0] pe_00_to_10_partial_sum;
    logic               pe_00_to_10_partial_sum_valid;
    logic signed [15:0] pe_01_to_11_partial_sum;
    logic               pe_01_to_11_partial_sum_valid;

    // TOP-LEFT PE (0,0)
    pe pe00 (
        .clk(clk),
        .reset(reset),
        .in_activation(in_row_0),
        .in_activation_valid(in_row_0_valid),
        .out_activation(pe_00_to_01_activation),
        .out_activation_valid(pe_00_to_01_activation_valid),
        .in_partial_sum(16'd0),
        .in_partial_sum_valid(1'b0),
        .out_partial_sum(pe_00_to_10_partial_sum),
        .out_partial_sum_valid(pe_00_to_10_partial_sum_valid),
        .loading_phase(loading_phase),
        .capture_weight(capture_weight_col_0),
        .in_weight(in_col_0),
        .in_weight_valid(in_col_0_valid),
        .out_weight(pe_00_to_10_weight),
        .out_weight_valid(pe_00_to_10_weight_valid)
    );

    // TOP-RIGHT PE (0,1)
    pe pe01 (
        .clk(clk),
        .reset(reset),
        .in_activation(pe_00_to_01_activation),
        .in_activation_valid(pe_00_to_01_activation_valid),
        .out_activation(),
        .out_activation_valid(),
        .in_partial_sum(16'd0),
        .in_partial_sum_valid(1'b0),
        .out_partial_sum(pe_01_to_11_partial_sum),
        .out_partial_sum_valid(pe_01_to_11_partial_sum_valid),
        .loading_phase(loading_phase),
        .capture_weight(capture_weight_col_1),
        .in_weight(in_col_1),
        .in_weight_valid(in_col_1_valid),
        .out_weight(pe_01_to_11_weight),
        .out_weight_valid(pe_01_to_11_weight_valid)
    );

    // BOTTOM-LEFT PE (1,0)
    pe pe10 (
        .clk(clk),
        .reset(reset),
        .in_activation(in_row_1),
        .in_activation_valid(in_row_1_valid),
        .out_activation(pe_10_to_11_activation),
        .out_activation_valid(pe_10_to_11_actication_valid),
        .in_partial_sum(pe_00_to_10_partial_sum),
        .in_partial_sum_valid(pe_00_to_10_partial_sum_valid),
        .out_partial_sum(out_partial_sum_0),
        .out_partial_sum_valid(out_partial_sum_0_valid),
        .loading_phase(loading_phase),
        .capture_weight(capture_weight_col_0),
        .in_weight(pe_00_to_10_weight),
        .in_weight_valid(pe_00_to_10_weight_valid),
        .out_weight(),
        .out_weight_valid()
    );

    // BOTTOM-RIGHT PE (1,1)
    pe pe11 (
        .clk(clk),
        .reset(reset),
        .in_activation(pe_10_to_11_activation),
        .in_activation_valid(pe_10_to_11_actication_valid),
        .out_activation(),
        .out_activation_valid(),
        .in_partial_sum(pe_01_to_11_partial_sum),
        .in_partial_sum_valid(pe_01_to_11_partial_sum_valid),
        .out_partial_sum(out_partial_sum_1),
        .out_partial_sum_valid(out_partial_sum_1_valid),
        .loading_phase(loading_phase),
        .capture_weight(capture_weight_col_1),
        .in_weight(pe_01_to_11_weight),
        .in_weight_valid(pe_01_to_11_weight_valid),
        .out_weight(),
        .out_weight_valid()
    );
endmodule
