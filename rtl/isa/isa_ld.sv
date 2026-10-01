`timescale 1ns / 1ps

import isa_pkg::*;

// LD engine: data FIFO words -> WMEM, UB, bias and quant tables
module isa_ld #(
    parameter int N        = 8,
    parameter int WMEM_AW  = 13,
    parameter int UB_AW    = 14,
    parameter int PAR_AW   = 8
) (
    input  logic                 clk,
    input  logic                 reset,

    input  logic                 q_valid,
    input  logic [UOP_W-1:0]     q_data,
    output logic                 q_pop,
    input  logic [63:0]          completed,
    output logic                 done_pulse,

    input  logic                 data_valid,
    input  logic                 ub_wbusy,       // ACT owns the UB write port this cycle
    input  logic [31:0]          data,
    output logic                 data_pop,

    output logic                 wmem_we,
    output logic [WMEM_AW-1:0]   wmem_waddr,
    output logic                 ub_we,
    output logic [UB_AW-1:0]     ub_waddr,
    output logic [N*8-1:0]       row_wdata,      // WMEM and UB rows
    output logic                 bias_we,
    output logic                 quant_we,
    output logic [PAR_AW-1:0]    par_waddr,
    output logic [N*32-1:0]      par_wdata,

    output logic                 idle
);

    localparam int WPR = N / 4;          // words per int8 row

    logic [63:0] insn, snap;
    assign insn = q_data[63:0];
    assign snap = q_data[127:64];
    logic [5:0] op;
    assign op = insn[63:58];

    logic        busy;
    logic [5:0]  cur_op;
    logic [16:0] items_left;
    logic [15:0] addr;
    logic [7:0]  word_idx;
    logic [N*32-1:0] buffer;

    logic int8_kind;
    assign int8_kind = (cur_op == OP_WR_WMEM || cur_op == OP_WR_UB);
    logic [7:0] words_per_item;
    assign words_per_item = int8_kind ? 8'(WPR) : 8'(N);

    // the item including the word arriving this cycle
    logic [N*32-1:0] item;
    always_comb begin
        item = buffer;
        item[32*word_idx +: 32] = data;
    end

    logic last_word;
    assign last_word = (word_idx == words_per_item - 8'd1);

    // hold a UB entry's last word while ACT is writing the UB
    assign data_pop  = busy && data_valid && !(last_word && cur_op == OP_WR_UB && ub_wbusy);
    assign row_wdata = item[N*8-1:0];
    assign par_wdata = item;

    always_comb begin
        wmem_we  = data_pop && last_word && cur_op == OP_WR_WMEM;
        ub_we    = data_pop && last_word && cur_op == OP_WR_UB;
        bias_we  = data_pop && last_word && cur_op == OP_WR_BIAS;
        quant_we = data_pop && last_word && cur_op == OP_WR_QUANT;
        wmem_waddr = WMEM_AW'(addr);
        ub_waddr   = UB_AW'(addr);
        par_waddr  = PAR_AW'(addr);
    end

    logic wait_ok;
    assign wait_ok   = wait_met(insn[51:48], snap, completed);
    assign q_pop     = q_valid && !busy && (op != OP_WAIT || wait_ok);
    assign idle      = !busy && !q_valid;

    always_ff @(posedge clk) begin
        if (reset) begin
            busy       <= 1'b0;
            cur_op     <= OP_NOP;
            items_left <= '0;
            addr       <= '0;
            word_idx   <= '0;
            buffer     <= '0;
            done_pulse <= 1'b0;
        end else begin
            done_pulse <= 1'b0;
            if (q_pop) begin
                if (op == OP_WAIT) begin
                    done_pulse <= 1'b1;
                end else begin
                    busy     <= 1'b1;
                    cur_op   <= op;
                    word_idx <= '0;
                    case (op)
                        OP_WR_WMEM: begin addr <= insn[47:32];        items_left <= 17'(insn[15:0]) + 1; end
                        OP_WR_UB:   begin addr <= 16'(insn[45:32]);   items_left <= 17'(insn[11:0]) + 1; end
                        default:    begin addr <= 16'(insn[39:32]);   items_left <= 17'(insn[7:0]) + 1; end
                    endcase
                end
            end
            if (data_pop) begin
                if (last_word) begin
                    word_idx <= '0;
                    addr     <= addr + 16'd1;
                    if (items_left == 17'd1) begin
                        busy       <= 1'b0;
                        done_pulse <= 1'b1;
                    end
                    items_left <= items_left - 17'd1;
                end else begin
                    buffer   <= item;
                    word_idx <= word_idx + 8'd1;
                end
            end
        end
    end

endmodule
