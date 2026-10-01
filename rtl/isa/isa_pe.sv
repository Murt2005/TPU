`timescale 1ns / 1ps

// overlap PE: w_next loads from the column's weight bus while w_cur computes;
// the first activation of a tile carries a flip bit that promotes w_next
module isa_pe (
    input  logic               clk,
    input  logic               reset,

    input  logic signed [7:0]  act_in,
    input  logic               first_in,
    input  logic               act_valid_in,
    input  logic signed [31:0] psum_in,

    input  logic               wsel,
    input  logic signed [7:0]  wdata,

    output logic signed [7:0]  act_out,
    output logic               first_out,
    output logic               act_valid_out,
    output logic signed [31:0] psum_out,
    output logic               psum_valid
);

    logic signed [7:0] w_cur, w_next, w_use;
    assign w_use = first_in ? w_next : w_cur;

    always_ff @(posedge clk) begin
        if (reset) begin
            w_cur         <= '0;
            w_next        <= '0;
            act_out       <= '0;
            first_out     <= 1'b0;
            act_valid_out <= 1'b0;
            psum_out      <= '0;
            psum_valid    <= 1'b0;
        end else begin
            if (wsel)
                w_next <= wdata;
            act_out       <= act_in;
            first_out     <= first_in;
            act_valid_out <= act_valid_in;
            psum_valid    <= act_valid_in;
            if (act_valid_in) begin
                psum_out <= 32'(w_use * act_in) + psum_in;
                if (first_in)
                    w_cur <= w_next;
            end
        end
    end

`ifndef SYNTHESIS
    // scheduler invariants: one weight write per flip, and never a flip without one
    logic pending;
    always_ff @(posedge clk) begin
        if (reset) begin
            pending <= 1'b0;
        end else begin
            if (act_valid_in && first_in && !pending)
                $fatal(1, "isa_pe %m: flip with no pending weight");
            if (wsel && pending && !(act_valid_in && first_in))
                $fatal(1, "isa_pe %m: weight overwritten before its flip");
            if (wsel)
                pending <= 1'b1;
            else if (act_valid_in && first_in)
                pending <= 1'b0;
        end
    end
`endif

endmodule
