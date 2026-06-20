`timescale 1ns/1ps

module pe (
    input  logic                clk,
    input  logic                reset,

    input  logic signed [7:0]   in_activation,
    output logic signed [7:0]   out_activation,
    input  logic                in_activation_valid,
    output logic                out_activation_valid,

    input  logic signed [15:0]  in_partial_sum,
    output logic signed [15:0]  out_partial_sum,
    input  logic                in_partial_sum_valid,
    output logic                out_partial_sum_valid,

    input  logic                loading_phase,
    input  logic                capture_weight,
    input  logic signed [7:0]   in_weight,
    output logic signed [7:0]   out_weight,
    input  logic                in_weight_valid,
    output logic                out_weight_valid
);

    // Internal storage for the stationary weight
    logic signed [7:0] weight_reg;

    always_ff @(posedge clk) begin
        if (reset) begin
            out_activation        <= 8'sd0;
            out_activation_valid  <= 1'b0;
            out_partial_sum       <= 16'sd0;
            out_partial_sum_valid <= 1'b0;
            out_weight            <= 8'sd0;
            out_weight_valid      <= 1'b0;
            weight_reg            <= 8'sd0;
        end else begin
            
            // ==========================================
            // 1. WEIGHT LOADING PHASE
            // ==========================================
            if (loading_phase) begin
                out_weight       <= in_weight;
                out_weight_valid <= in_weight_valid;
                
                // Capture weight locally only if the incoming weight is valid
                if (capture_weight && in_weight_valid) begin
                    weight_reg   <= in_weight;
                end
            end else begin
                out_weight       <= 8'sd0;
                out_weight_valid <= 1'b0;
            end

            // ==========================================
            // 2. COMPUTATION PHASE
            // ==========================================
            if (!loading_phase) begin
                // Register and pass downstream the activation and its valid tag
                out_activation       <= in_activation;
                out_activation_valid <= in_activation_valid;

                // Multiply-Accumulate logic gates on valid input data
                if (in_activation_valid) begin
                    out_partial_sum       <= (weight_reg * in_activation) + (in_partial_sum_valid ? in_partial_sum : 16'sd0);
                    out_partial_sum_valid <= 1'b1;
                end else begin
                    // no activation this cycle, pass incoming partial sum straight through unchanged
                    out_partial_sum       <= in_partial_sum;
                    out_partial_sum_valid <= in_partial_sum_valid;
                end
            end else begin
                // Clear execution channels when explicitly loading weights
                out_activation        <= 8'sd0;
                out_activation_valid  <= 1'b0;
                out_partial_sum       <= 16'sd0;
                out_partial_sum_valid <= 1'b0;
            end
            
        end
    end

endmodule
