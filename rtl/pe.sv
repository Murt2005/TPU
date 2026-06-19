`timescale 1ns/1ps

module pe (
    input  logic                clk,
    input  logic                reset,

    input  logic signed [7:0]   in_activation,
    output logic signed [7:0]   out_activation,

    input  logic signed [15:0]  in_partial_sum,
    output logic signed [15:0]  out_partial_sum,

    input  logic                loading_phase,
    input  logic                capture_weight,
    input  logic signed [7:0]   in_weight,
    output logic signed [7:0]   out_weight
);

    logic signed [7:0] weight;

    always_ff @(posedge clk) begin
        if (reset) begin
            out_activation <= 8'd0;
            out_partial_sum <= 16'd0;
            out_weight <= 8'd0;
            weight <= 8'd0;
        end else begin
            // Weight loading mode
            if (loading_phase) begin
                out_weight <= in_weight;
                if (capture_weight) begin
                    weight <= in_weight;
                end
            end else begin
                out_weight <= 8'd0;
            end

            if (!loading_phase) begin
                // Compute mode
                out_activation <= in_activation;
                out_partial_sum <= weight * in_activation + in_partial_sum;
            end else begin
                out_activation <= 8'd0;
                out_partial_sum <= 16'd0;
            end
        end
    end
endmodule
