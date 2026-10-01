`timescale 1ns / 1ps

import isa_pkg::*;

// dispatcher: decodes in order, one instruction per cycle, into four engine queues
module isa_dispatch #(
    parameter int N           = 8,
    parameter int WMEM_ROWS   = 8192,
    parameter int UB_DEPTH    = 16384,
    parameter int ACC_DEPTH   = 1024,
    parameter int PARAM_DEPTH = 256
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        insn_valid,
    input  logic [63:0] insn,
    output logic        insn_pop,

    // queue pushes, one entry per engine
    output logic [3:0]          q_push,
    output logic [UOP_W-1:0]    q_data,
    input  logic [3:0]          q_full,

    input  logic [63:0]         completed,   // 4 x 16-bit, from the engines
    output logic [63:0]         dispatched,

    output logic        err,
    output logic [7:0]  err_code,
    output logic [31:0] err_seq,
    output logic        done,
    output logic [15:0] tag,
    input  logic        clear_done,
    output logic        busy                 // fence pending
);

    logic [31:0] seq;
    logic [31:0] wbase;          // shadow of WT's WBASE, for weight range checks
    logic        fence;
    logic [15:0] fence_tag;

    // -- decode -------------------------------------------------------------
    logic [5:0] op;
    assign op = insn[63:58];

    logic [63:0] legal;
    logic        known;
    always_comb begin
        known = 1'b1;
        case (op)
            OP_NOP:                     legal = MASK_NOP;
            OP_WR_WMEM:                 legal = MASK_WR_WMEM;
            OP_WR_UB, OP_RD_UB:         legal = MASK_WR_UB;
            OP_WR_BIAS, OP_WR_QUANT:    legal = MASK_WR_PAR;
            OP_RD_DDR_UB:               legal = MASK_RD_DDR;
            OP_SET_WBASE, OP_SET_OBASE: legal = MASK_SET32;
            OP_MATMUL:                  legal = MASK_MATMUL;
            OP_ACTIVATE:                legal = MASK_ACT;
            OP_WAIT:                    legal = MASK_WAIT;
            OP_SIGNAL:                  legal = MASK_SIGNAL;
            default: begin              legal = '0; known = 1'b0; end
        endcase
    end

    // fields (counts stored minus one)
    logic [63:0] f_n_rows, f_n_ub, f_n_par, f_m, f_kt, f_nb, f_am, f_anb;
    logic [63:0] f_wmem_row, f_ub_addr, f_par, f_acc_addr, f_mm_ub, f_act_acc, f_act_ub, f_act_par;
    logic [1:0]  f_func, f_dst;
    logic        f_rq, f_bias, f_wsrc;
    always_comb begin
        f_n_rows   = 64'(insn[15:0]) + 1;
        f_n_ub     = 64'(insn[11:0]) + 1;
        f_n_par    = 64'(insn[7:0]) + 1;
        f_wmem_row = 64'(insn[47:32]);
        f_ub_addr  = 64'(insn[45:32]);
        f_par      = 64'(insn[39:32]);
        f_wsrc     = insn[56];
        f_m        = 64'(insn[55:48]) + 1;
        f_kt       = 64'(insn[47:36]) + 1;
        f_nb       = 64'(insn[35:26]) + 1;
        f_acc_addr = 64'(insn[25:16]);
        f_mm_ub    = 64'(insn[15:2]);
        f_func     = insn[57:56];
        f_rq       = insn[55];
        f_dst      = insn[54:53];
        f_bias     = insn[52];
        f_anb      = 64'(insn[51:42]) + 1;
        f_am       = 64'(insn[41:34]) + 1;
        f_act_acc  = 64'(insn[33:24]);
        f_act_ub   = 64'(insn[23:10]);
        f_act_par  = 64'(insn[9:2]);
    end

    logic [7:0] code;
    always_comb begin
        code = ERR_NONE;
        if (!known)
            code = ERR_OPCODE;
        else if ((insn & ~legal) != 0)
            code = ERR_RESERVED;
        else if (op == OP_ACTIVATE && (f_func[1] || f_dst == 2'd3))
            code = ERR_RESERVED;
        else if (op == OP_RD_DDR_UB || op == OP_SET_OBASE
                 || (op == OP_MATMUL && f_wsrc)
                 || (op == OP_ACTIVATE && (f_dst == DST_DDR || f_rq)))
            code = ERR_UNIMPL;   // phase 1: no DDR3, no requantizer
        else if (op == OP_ACTIVATE && f_dst == DST_UB && !f_rq)
            code = ERR_COMBO;
        else case (op)
            OP_WR_WMEM:  if (f_wmem_row + f_n_rows > 64'(WMEM_ROWS)) code = ERR_RANGE;
            OP_WR_UB,
            OP_RD_UB:    if (f_ub_addr + f_n_ub > 64'(UB_DEPTH)) code = ERR_RANGE;
            OP_WR_BIAS,
            OP_WR_QUANT: if (f_par + f_n_par > 64'(PARAM_DEPTH)) code = ERR_RANGE;
            OP_MATMUL:   if (f_acc_addr + f_nb * f_m > 64'(ACC_DEPTH)
                             || f_mm_ub + f_kt * f_m > 64'(UB_DEPTH)
                             || (64'(wbase) + f_nb * f_kt) * N > 64'(WMEM_ROWS)) code = ERR_RANGE;
            OP_ACTIVATE: if (f_act_acc + f_anb * f_am > 64'(ACC_DEPTH)
                             || ((f_bias || f_rq) && f_act_par + f_anb > 64'(PARAM_DEPTH))
                             || (f_dst == DST_UB && f_act_ub + f_anb * f_am > 64'(UB_DEPTH)))
                             code = ERR_RANGE;
            default: ;
        endcase
    end

    // which queues an instruction goes to
    logic [3:0] targets;
    always_comb begin
        case (op)
            OP_WR_WMEM, OP_WR_UB, OP_WR_BIAS, OP_WR_QUANT: targets = 4'b0001;
            OP_SET_WBASE:                                  targets = 4'b0010;
            OP_MATMUL:                                     targets = 4'b0110;
            OP_ACTIVATE, OP_RD_UB:                         targets = 4'b1000;
            OP_WAIT:                                       targets = 4'b0001 << insn[57:56];
            default:                                       targets = 4'b0000;   // NOP, SIGNAL
        endcase
    end

    logic all_quiet;
    assign all_quiet = (completed == dispatched);

    logic go;
    assign go = insn_valid && !err && !fence && code == ERR_NONE && (targets & q_full) == 0;

    assign insn_pop = go;
    assign q_push   = go ? targets : 4'b0000;
    // a WAIT carries the counts dispatched so far, not including itself
    assign q_data   = {dispatched, insn};
    assign busy     = fence;

    always_ff @(posedge clk) begin
        if (reset) begin
            seq        <= '0;
            wbase      <= '0;
            fence      <= 1'b0;
            fence_tag  <= '0;
            dispatched <= '0;
            err        <= 1'b0;
            err_code   <= '0;
            err_seq    <= '0;
            done       <= 1'b0;
            tag        <= '0;
        end else begin
            if (clear_done)
                done <= 1'b0;

            if (insn_valid && !err && !fence && code != ERR_NONE) begin
                err      <= 1'b1;
                err_code <= code;
                err_seq  <= seq;
            end

            if (go) begin
                seq <= seq + 1;
                for (int e = 0; e < 4; e++)
                    if (targets[e])
                        dispatched[16*e +: 16] <= dispatched[16*e +: 16] + 16'd1;
                if (op == OP_SET_WBASE)
                    wbase <= insn[31:0];
                else if (op == OP_MATMUL)
                    wbase <= wbase + 32'(f_nb * f_kt);
                if (op == OP_SIGNAL) begin
                    fence     <= 1'b1;
                    fence_tag <= insn[15:0];
                end
            end

            if (fence && all_quiet) begin
                fence <= 1'b0;
                done  <= 1'b1;
                tag   <= fence_tag;
            end
        end
    end

endmodule
