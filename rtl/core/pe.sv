`timescale 1ns / 1ps

// overlap PE: w_next loads from the column's weight bus while w_cur computes;
// the first activation of a tile carries a flip bit that promotes w_next
module pe (
    input  logic               clk,
    input  logic               reset,

    input  logic signed [7:0]  activation_in,
    input  logic               first_in,
    input  logic               activation_valid_in,
    input  logic signed [31:0] partial_sum_in,

    input  logic               weight_select,
    input  logic signed [7:0]  weight_data,

    output logic signed [7:0]  activation_out,
    output logic               first_out,
    output logic               activation_valid_out,
    output logic signed [31:0] partial_sum_out,
    output logic               partial_sum_valid
);

    logic signed [7:0] weight_current, weight_next, weight_in_use;
    assign weight_in_use = first_in ? weight_next : weight_current;

    always_ff @(posedge clk) begin
        if (reset) begin
            weight_current       <= '0;
            weight_next          <= '0;
            activation_out       <= '0;
            first_out            <= 1'b0;
            activation_valid_out <= 1'b0;
            partial_sum_out      <= '0;
            partial_sum_valid    <= 1'b0;
        end else begin
            if (weight_select)
                weight_next <= weight_data;
            activation_out       <= activation_in;
            first_out            <= first_in;
            activation_valid_out <= activation_valid_in;
            partial_sum_valid    <= activation_valid_in;
            if (activation_valid_in) begin
                partial_sum_out <= 32'(weight_in_use * activation_in) + partial_sum_in;
                if (first_in)
                    weight_current <= weight_next;
            end
        end
    end

`ifndef SYNTHESIS
    // scheduler invariants: one weight write per flip, and never a flip without one
    logic weight_pending;
    always_ff @(posedge clk) begin
        if (reset) begin
            weight_pending <= 1'b0;
        end else begin
            if (activation_valid_in && first_in && !weight_pending)
                $fatal(1, "pe %m: flip with no pending weight");
            if (weight_select && weight_pending && !(activation_valid_in && first_in))
                $fatal(1, "pe %m: weight overwritten before its flip");
            if (weight_select)
                weight_pending <= 1'b1;
            else if (activation_valid_in && first_in)
                weight_pending <= 1'b0;
        end
    end
`endif

endmodule
