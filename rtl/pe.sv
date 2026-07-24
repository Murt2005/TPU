`timescale 1ns/1ps

// pe — one processing element of the weight-stationary systolic array.
//
// Holds a single stationary int8 weight and, each cycle, forms one MAC step of
// a dot product: (weight * streaming activation) + incoming partial sum.
//
// Two phases, selected by loading_phase:
//   loading_phase = 1  weight load: in_weight is registered downward one PE per
//                      cycle (out_weight); when capture_weight is asserted the
//                      PE latches in_weight into its stationary weight_reg. The
//                      activation/psum datapath is held idle.
//   loading_phase = 0  compute: in_activation shifts right to out_activation,
//                      and out_partial_sum = weight_reg*in_activation +
//                      in_partial_sum (passes psum through unchanged when the
//                      activation isn't valid). Weight outputs held idle.
//
// Latency: one registered cycle on every output (activation right, weight down,
// partial sum down). Synchronous active-high reset. Widths are fixed int8
// data / int16 partial sum (the array-level modules parameterize these; the PE
// is the hard-wired leaf). mmu.sv builds the ARRAY_ROWS x NUM_COLS grid from
// these; the generic multiply on line ~55 is what yosys -dsp maps to an
// SB_MAC16 (see pe_pair.sv for the two-PEs-per-DSP iCE40 variant).
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
            
            if (loading_phase) begin
                out_weight       <= in_weight;
                out_weight_valid <= in_weight_valid;
                
                if (capture_weight && in_weight_valid) begin
                    weight_reg   <= in_weight;
                end
            end else begin
                out_weight       <= 8'sd0;
                out_weight_valid <= 1'b0;
            end

            if (!loading_phase) begin
                out_activation       <= in_activation;
                out_activation_valid <= in_activation_valid;

                if (in_activation_valid) begin
                    out_partial_sum       <= (weight_reg * in_activation) + (in_partial_sum_valid ? in_partial_sum : 16'sd0);
                    out_partial_sum_valid <= 1'b1;
                end else begin
                    out_partial_sum       <= in_partial_sum;
                    out_partial_sum_valid <= in_partial_sum_valid;
                end
            end else begin
                out_activation        <= 8'sd0;
                out_activation_valid  <= 1'b0;
                out_partial_sum       <= 16'sd0;
                out_partial_sum_valid <= 1'b0;
            end
            
        end
    end

endmodule
