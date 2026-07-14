`timescale 1ns / 1ps

// pe_pair
// -------
// Two complete processing elements packed onto ONE hand-instantiated
// SB_MAC16 in dual-8x8 signed mode (MODE_8x8=1, A_SIGNED/B_SIGNED=1):
// the top half multiplies A[15:8]*B[15:8] (product F) into the top
// 16-bit ADDSUB with upper input C, the bottom half multiplies
// A[7:0]*B[7:0] (product G) into the bottom ADDSUB with upper input D,
// and both halves latch their sum in the DSP's own output register
// ({TOP,BOT}OUTPUT_SELECT=1). One DSP block therefore provides both
// PEs' multiply + psum-add + pipeline register; only weight capture,
// activation forwarding, and the valid bits remain in fabric (pe.sv
// minus its multiplier).
//
// The port list is exactly two pe.sv interfaces (_t = top PE, _b =
// bottom PE) sharing clk/reset/loading_phase/capture_weight, so mmu.sv
// can instantiate one pe_pair in place of the two `pe`s of adjacent
// rows (r, r+1) in a column with identical wiring: the top half's
// registered psum output leaves on out_partial_sum_t, routes through
// fabric (mmu's existing psum_out[r] -> psum_in[r+1] nets), and
// re-enters as in_partial_sum_b -> the DSP's D input -- that fabric
// hop IS the inter-PE pipeline register the systolic array needs.
//
// Bit-exactness vs. pe.sv (verified cycle-accurate by pe_pair_tb):
//   - pe.sv computes out <= w*a + (psum_valid ? psum : 0) when the
//     activation is valid, else passes psum through: out <= psum.
//     The DSP adder always computes F + C (resp. G + D), so we gate
//     the inputs instead: activation forced to 0 when invalid (product
//     0 => adder passes C through), C forced to 0 only in the
//     "valid activation, invalid psum" case.
//   - pe.sv clears its psum output synchronously during loading_phase;
//     we force both adder inputs to 0 during loading_phase so the DSP
//     output register clears on the same edge (ORST is used for reset
//     only, where the async-vs-sync difference is unobservable: reset
//     is held across many cycles and released between edges).
//   - 16-bit wraparound: the DSP truncates each product to 16 bits and
//     adds mod 2^16, matching pe.sv's 16-bit signed arithmetic.
module pe_pair (
    input  logic                clk,
    input  logic                reset,
    input  logic                loading_phase,
    input  logic                capture_weight,

    // ---- top PE (array row r) ----
    input  logic signed [7:0]   in_activation_t,
    output logic signed [7:0]   out_activation_t,
    input  logic                in_activation_valid_t,
    output logic                out_activation_valid_t,

    input  logic signed [15:0]  in_partial_sum_t,
    output logic signed [15:0]  out_partial_sum_t,
    input  logic                in_partial_sum_valid_t,
    output logic                out_partial_sum_valid_t,

    input  logic signed [7:0]   in_weight_t,
    output logic signed [7:0]   out_weight_t,
    input  logic                in_weight_valid_t,
    output logic                out_weight_valid_t,

    // ---- bottom PE (array row r+1) ----
    input  logic signed [7:0]   in_activation_b,
    output logic signed [7:0]   out_activation_b,
    input  logic                in_activation_valid_b,
    output logic                out_activation_valid_b,

    input  logic signed [15:0]  in_partial_sum_b,
    output logic signed [15:0]  out_partial_sum_b,
    input  logic                in_partial_sum_valid_b,
    output logic                out_partial_sum_valid_b,

    input  logic signed [7:0]   in_weight_b,
    output logic signed [7:0]   out_weight_b,
    input  logic                in_weight_valid_b,
    output logic                out_weight_valid_b
);

    // Stationary weights (fabric, same capture rule as pe.sv)
    logic signed [7:0] weight_reg_t;
    logic signed [7:0] weight_reg_b;

    always_ff @(posedge clk) begin
        if (reset) begin
            weight_reg_t           <= 8'sd0;
            weight_reg_b           <= 8'sd0;
            out_weight_t           <= 8'sd0;
            out_weight_valid_t     <= 1'b0;
            out_weight_b           <= 8'sd0;
            out_weight_valid_b     <= 1'b0;
            out_activation_t       <= 8'sd0;
            out_activation_valid_t <= 1'b0;
            out_activation_b       <= 8'sd0;
            out_activation_valid_b <= 1'b0;
            out_partial_sum_valid_t <= 1'b0;
            out_partial_sum_valid_b <= 1'b0;
        end else begin
            // Weight shift chain (active during loading, cleared otherwise)
            if (loading_phase) begin
                out_weight_t       <= in_weight_t;
                out_weight_valid_t <= in_weight_valid_t;
                out_weight_b       <= in_weight_b;
                out_weight_valid_b <= in_weight_valid_b;
                if (capture_weight && in_weight_valid_t) weight_reg_t <= in_weight_t;
                if (capture_weight && in_weight_valid_b) weight_reg_b <= in_weight_b;
            end else begin
                out_weight_t       <= 8'sd0;
                out_weight_valid_t <= 1'b0;
                out_weight_b       <= 8'sd0;
                out_weight_valid_b <= 1'b0;
            end

            // Activation forwarding + psum valid tags (compute phase)
            if (!loading_phase) begin
                out_activation_t       <= in_activation_t;
                out_activation_valid_t <= in_activation_valid_t;
                out_activation_b       <= in_activation_b;
                out_activation_valid_b <= in_activation_valid_b;
                out_partial_sum_valid_t <= in_activation_valid_t ? 1'b1 : in_partial_sum_valid_t;
                out_partial_sum_valid_b <= in_activation_valid_b ? 1'b1 : in_partial_sum_valid_b;
            end else begin
                out_activation_t       <= 8'sd0;
                out_activation_valid_t <= 1'b0;
                out_activation_b       <= 8'sd0;
                out_activation_valid_b <= 1'b0;
                out_partial_sum_valid_t <= 1'b0;
                out_partial_sum_valid_b <= 1'b0;
            end
        end
    end

    // Input gating that maps pe.sv's conditional MAC onto the DSP's
    // unconditional "product + upper input" adders (see header).
    logic signed [7:0] act_gated_t, act_gated_b;
    logic       [15:0] upper_t, upper_b;

    always_comb begin
        act_gated_t = (!loading_phase && in_activation_valid_t) ? in_activation_t : 8'sd0;
        act_gated_b = (!loading_phase && in_activation_valid_b) ? in_activation_b : 8'sd0;

        if (loading_phase) begin
            upper_t = 16'd0;
            upper_b = 16'd0;
        end else begin
            upper_t = (in_activation_valid_t && !in_partial_sum_valid_t)
                      ? 16'd0 : unsigned'(in_partial_sum_t);
            upper_b = (in_activation_valid_b && !in_partial_sum_valid_b)
                      ? 16'd0 : unsigned'(in_partial_sum_b);
        end
    end

    logic [31:0] mac_o;
    assign out_partial_sum_t = signed'(mac_o[31:16]);
    assign out_partial_sum_b = signed'(mac_o[15:0]);

    SB_MAC16 #(
        .NEG_TRIGGER              (1'b0),
        .C_REG                    (1'b0),
        .A_REG                    (1'b0),
        .B_REG                    (1'b0),
        .D_REG                    (1'b0),
        .TOP_8x8_MULT_REG         (1'b0),
        .BOT_8x8_MULT_REG         (1'b0),
        .PIPELINE_16x16_MULT_REG1 (1'b0),
        .PIPELINE_16x16_MULT_REG2 (1'b0),
        .TOPOUTPUT_SELECT         (2'd1),  // registered top adder output
        .TOPADDSUB_LOWERINPUT     (2'd1),  // F = A[15:8]*B[15:8]
        .TOPADDSUB_UPPERINPUT     (1'b1),  // C port
        .TOPADDSUB_CARRYSELECT    (2'd0),  // constant 0: halves independent
        .BOTOUTPUT_SELECT         (2'd1),  // registered bottom adder output
        .BOTADDSUB_LOWERINPUT     (2'd1),  // G = A[7:0]*B[7:0]
        .BOTADDSUB_UPPERINPUT     (1'b1),  // D port
        .BOTADDSUB_CARRYSELECT    (2'd0),
        .MODE_8x8                 (1'b1),
        .A_SIGNED                 (1'b1),
        .B_SIGNED                 (1'b1)
    ) u_mac16 (
        .CLK        (clk),
        .CE         (1'b1),
        .A          ({unsigned'(weight_reg_t), unsigned'(weight_reg_b)}),
        .B          ({unsigned'(act_gated_t), unsigned'(act_gated_b)}),
        .C          (upper_t),
        .D          (upper_b),
        .AHOLD      (1'b0),
        .BHOLD      (1'b0),
        .CHOLD      (1'b0),
        .DHOLD      (1'b0),
        .IRSTTOP    (reset),
        .IRSTBOT    (reset),
        .ORSTTOP    (reset),
        .ORSTBOT    (reset),
        .OLOADTOP   (1'b0),
        .OLOADBOT   (1'b0),
        .ADDSUBTOP  (1'b0),
        .ADDSUBBOT  (1'b0),
        .OHOLDTOP   (1'b0),
        .OHOLDBOT   (1'b0),
        .CI         (1'b0),
        .ACCUMCI    (1'b0),
        .SIGNEXTIN  (1'b0),
        .O          (mac_o),
        .CO         (),
        .ACCUMCO    (),
        .SIGNEXTOUT ()
    );

endmodule
