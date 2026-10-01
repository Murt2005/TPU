`timescale 1ns / 1ps

// two PEs on one SB_MAC16 in dual-8x8 signed mode; ports are two pe.sv interfaces
// (_t = row r, _b = row r+1) so mmu.sv swaps it in for a pair of pe instances
module pe_pair (
    input  logic                clk,
    input  logic                reset,
    input  logic                loading_phase,
    input  logic                capture_weight,

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

    // the DSP always adds product + upper input, so gate the inputs to reproduce
    // pe.sv: act 0 when invalid passes psum through, upper 0 when psum is invalid,
    // both 0 while loading to match pe.sv's synchronous psum clear
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
