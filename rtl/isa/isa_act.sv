`timescale 1ns / 1ps

import isa_pkg::*;

// ACT engine: ACC rows -> bias -> ReLU/identity -> host out FIFO, plus RD_UB.
// phase 1: no requantizer and no UB/DDR3 destination (rejected at decode).
// shares the ACC and UB read ports with MM, which has priority
module isa_act #(
    parameter int N      = 8,
    parameter int UB_AW  = 14,
    parameter int ACC_AW = 10,
    parameter int PAR_AW = 8
) (
    input  logic                 clk,
    input  logic                 reset,

    input  logic                 q_valid,
    input  logic [UOP_W-1:0]     q_data,
    output logic                 q_pop,
    input  logic [63:0]          completed,
    output logic                 done_pulse,

    output logic                 acc_re,
    output logic [ACC_AW-1:0]    acc_raddr,
    input  logic                 acc_busy,       // MM owns the port this cycle
    input  logic [N*32-1:0]      acc_rdata,

    output logic [PAR_AW-1:0]    bias_raddr,
    input  logic [N*32-1:0]      bias_rdata,

    output logic                 ub_re,
    output logic [UB_AW-1:0]     ub_raddr,
    input  logic                 ub_busy,
    input  logic [N*8-1:0]       ub_rdata,

    output logic                 out_push,
    output logic [31:0]          out_word,
    input  logic                 out_full,

    output logic                 idle
);

    localparam int WPR = N / 4;

    logic [63:0] insn, snap;
    assign insn = q_data[63:0];
    assign snap = q_data[127:64];
    logic [5:0] op;
    assign op = insn[63:58];

    typedef enum logic [1:0] {S_IDLE, S_READ, S_LATCH, S_EMIT} state_t;
    state_t state;

    logic        is_rd_ub;
    logic        relu, use_bias;
    logic [8:0]  m;
    logic [10:0] nb, b;
    logic [8:0]  i;
    logic [15:0] row_addr;      // ACC row, or UB entry for RD_UB
    logic [15:0] items_left;    // RD_UB entries
    logic [7:0]  par;
    logic [7:0]  w;             // word within the row being emitted
    logic [N*32-1:0] row;       // computed row, one word per column (or packed int8)

    assign acc_raddr  = ACC_AW'(row_addr);
    assign ub_raddr   = UB_AW'(row_addr);
    assign bias_raddr = PAR_AW'(par);
    assign acc_re     = state == S_READ && !is_rd_ub && !acc_busy;
    assign ub_re      = state == S_READ && is_rd_ub && !ub_busy;

    logic [7:0] words_per_row;
    assign words_per_row = is_rd_ub ? 8'(WPR) : 8'(N);
    assign out_push = state == S_EMIT && !out_full;
    assign out_word = row[32*w +: 32];

    logic wait_ok;
    assign wait_ok = wait_met(insn[51:48], snap, completed);
    assign q_pop   = q_valid && state == S_IDLE && (op != OP_WAIT || wait_ok);
    assign idle    = state == S_IDLE && !q_valid;

    logic [N*32-1:0] act_row;
    always_comb
        for (int c = 0; c < N; c++) begin
            logic signed [31:0] v;
            v = acc_rdata[32*c +: 32] + (use_bias ? bias_rdata[32*c +: 32] : 32'd0);
            act_row[32*c +: 32] = (relu && v < 0) ? 32'd0 : v;
        end

    always_ff @(posedge clk) begin
        if (reset) begin
            state      <= S_IDLE;
            is_rd_ub   <= 1'b0;
            relu       <= 1'b0;
            use_bias   <= 1'b0;
            m          <= '0;
            nb         <= '0;
            b          <= '0;
            i          <= '0;
            row_addr   <= '0;
            items_left <= '0;
            par        <= '0;
            w          <= '0;
            row        <= '0;
            done_pulse <= 1'b0;
        end else begin
            done_pulse <= 1'b0;
            case (state)
                S_IDLE: if (q_pop) begin
                    if (op == OP_ACTIVATE) begin
                        is_rd_ub <= 1'b0;
                        relu     <= insn[57:56] == 2'd1;
                        use_bias <= insn[52];
                        nb       <= 11'(insn[51:42]) + 11'd1;
                        m        <= 9'(insn[41:34]) + 9'd1;
                        row_addr <= 16'(insn[33:24]);
                        par      <= insn[9:2];
                        b        <= '0;
                        i        <= '0;
                        state    <= S_READ;
                    end else if (op == OP_RD_UB) begin
                        is_rd_ub   <= 1'b1;
                        row_addr   <= 16'(insn[45:32]);
                        items_left <= 16'(insn[11:0]) + 16'd1;
                        state      <= S_READ;
                    end else begin
                        done_pulse <= 1'b1;            // WAIT
                    end
                end
                S_READ: if (is_rd_ub ? !ub_busy : !acc_busy) state <= S_LATCH;
                S_LATCH: begin                         // read data valid this cycle
                    row   <= is_rd_ub ? (N*32)'(ub_rdata) : act_row;
                    w     <= '0;
                    state <= S_EMIT;
                end
                S_EMIT: if (out_push) begin
                    if (w == words_per_row - 8'd1) begin
                        row_addr <= row_addr + 16'd1;
                        state    <= S_READ;
                        if (is_rd_ub) begin
                            items_left <= items_left - 16'd1;
                            if (items_left == 16'd1) begin
                                state      <= S_IDLE;
                                done_pulse <= 1'b1;
                            end
                        end else if (i == m - 9'd1) begin
                            i   <= '0;
                            par <= par + 8'd1;
                            if (b == nb - 11'd1) begin
                                state      <= S_IDLE;
                                done_pulse <= 1'b1;
                            end
                            b <= b + 11'd1;
                        end else begin
                            i <= i + 9'd1;
                        end
                    end else begin
                        w <= w + 8'd1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
