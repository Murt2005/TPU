`timescale 1ns / 1ps

import isa_pkg::*;

// WT engine: WMEM tiles -> the tile slot MM drains. phase 1 has one slot, so a
// fetch only starts once MM has taken the previous tile
module isa_wt #(
    parameter int N       = 8,
    parameter int WMEM_AW = 13
) (
    input  logic                 clk,
    input  logic                 reset,

    input  logic                 q_valid,
    input  logic [UOP_W-1:0]     q_data,
    output logic                 q_pop,
    input  logic [63:0]          completed,
    output logic                 done_pulse,

    output logic [WMEM_AW-1:0]   wmem_raddr,
    input  logic [N*8-1:0]       wmem_rdata,     // one cycle after the address

    output logic [N-1:0][N*8-1:0] slot,          // row r = the K index that multiplies chunk byte r
    output logic                 slot_full,
    input  logic                 slot_take,

    output logic                 idle
);

    logic [63:0] insn, snap;
    assign insn = q_data[63:0];
    assign snap = q_data[127:64];
    logic [5:0] op;
    assign op = insn[63:58];

    logic [31:0] wbase;
    logic        busy;
    logic [31:0] tiles_left;
    logic [31:0] tile;
    logic [7:0]  row;          // next row address to issue
    logic        rd_pending;   // a WMEM read is returning this cycle
    logic [7:0]  rd_row;

    logic fetching;
    assign fetching = busy && !slot_full;

    assign wmem_raddr = WMEM_AW'(tile * N + 32'(row));
    assign q_pop      = q_valid && !busy && (op != OP_WAIT || wait_met(insn[51:48], snap, completed));
    assign idle       = !busy && !q_valid;

    always_ff @(posedge clk) begin
        if (reset) begin
            wbase      <= '0;
            busy       <= 1'b0;
            tiles_left <= '0;
            tile       <= '0;
            row        <= '0;
            rd_pending <= 1'b0;
            rd_row     <= '0;
            slot_full  <= 1'b0;
            done_pulse <= 1'b0;
            slot       <= '0;
        end else begin
            done_pulse <= 1'b0;
            if (slot_take)
                slot_full <= 1'b0;

            if (q_pop) begin
                case (op)
                    OP_SET_WBASE: begin
                        wbase      <= insn[31:0];
                        done_pulse <= 1'b1;
                    end
                    OP_MATMUL: begin
                        busy       <= 1'b1;
                        tile       <= wbase;
                        tiles_left <= (32'(insn[35:26]) + 1) * (32'(insn[47:36]) + 1);
                        row        <= '0;
                    end
                    default: done_pulse <= 1'b1;   // WAIT
                endcase
            end

            // issue one row read per cycle while the slot is free
            rd_pending <= 1'b0;
            if (fetching && row < 8'(N)) begin
                rd_pending <= 1'b1;
                rd_row     <= row;
                row        <= row + 8'd1;
            end

            if (rd_pending) begin
                slot[rd_row] <= wmem_rdata;
                if (rd_row == 8'(N - 1)) begin
                    slot_full <= 1'b1;
                    row       <= '0;
                    tile      <= tile + 32'd1;
                    if (tiles_left == 32'd1) begin
                        busy       <= 1'b0;
                        wbase      <= tile + 32'd1;
                        done_pulse <= 1'b1;
                    end
                    tiles_left <= tiles_left - 32'd1;
                end
            end
        end
    end

endmodule
