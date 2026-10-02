`timescale 1ns / 1ps

// Processing Element (PE)
module pe (
    input  logic               clk,
    input  logic               reset,

    input  logic signed [7:0]  activation_in,
    input  logic               activation_valid_in,
    input  logic               weight_flip_in,

    input  logic signed [31:0] partial_sum_in,
    input  logic               partial_sum_valid_in,

    input  logic signed [7:0]  weight_in,
    input  logic               weight_valid_in,

    output logic signed [7:0]  activation_out,
    output logic               activation_valid_out,
    output logic               weight_flip_out,

    output logic signed [31:0] partial_sum_out,
    output logic               partial_sum_valid_out
);

    logic signed [7:0] weight_current, weight_next, weight_in_use;
    assign weight_in_use = weight_flip_in ? weight_next : weight_current;

    always_ff @(posedge clk) begin
        if (reset) begin
            weight_current        <= '0;
            weight_next           <= '0;
            activation_out        <= '0;
            weight_flip_out       <= 1'b0;
            activation_valid_out  <= 1'b0;
            partial_sum_out       <= '0;
            partial_sum_valid_out <= 1'b0;
        end else begin
            if (weight_valid_in)
                weight_next <= weight_in;
            activation_out        <= activation_in;
            weight_flip_out       <= weight_flip_in;
            activation_valid_out  <= activation_valid_in;
            partial_sum_valid_out <= activation_valid_in && partial_sum_valid_in;
            if (activation_valid_in) begin
                partial_sum_out <= 32'(weight_in_use * activation_in) + partial_sum_in;
                if (weight_flip_in)
                    weight_current <= weight_next;
            end
        end
    end

`ifndef SYNTHESIS
    // scheduler invariants: one weight write per flip, never a flip without one,
    // and the partial sum from above arrives with its activation
    logic weight_pending;
    always_ff @(posedge clk) begin
        if (reset) begin
            weight_pending <= 1'b0;
        end else begin
            if (activation_valid_in && weight_flip_in && !weight_pending)
                $fatal(1, "pe %m: flip with no pending weight");
            if (weight_valid_in && weight_pending && !(activation_valid_in && weight_flip_in))
                $fatal(1, "pe %m: weight overwritten before its flip");
            if (activation_valid_in && !partial_sum_valid_in)
                $fatal(1, "pe %m: activation without a valid partial sum");
            if (weight_valid_in)
                weight_pending <= 1'b1;
            else if (activation_valid_in && weight_flip_in)
                weight_pending <= 1'b0;
        end
    end
`endif

endmodule
