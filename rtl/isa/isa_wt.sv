`timescale 1ns / 1ps

import isa_pkg::*;

// WT engine: WMEM tiles -> a two-slot tile buffer MM drains in order. reads issue
// back to back across tiles, so a tile lands every N cycles while a slot is free
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

    output logic [N-1:0][N*8-1:0] slot,          // the oldest full tile; row r = K index r
    output logic                 slot_full,
    input  logic                 slot_take,

    output logic                 idle
);

    logic [63:0] insn, snap;
    assign insn = q_data[63:0];
    assign snap = q_data[127:64];
    logic [5:0] op;
    assign op = insn[63:58];

    logic [N-1:0][N*8-1:0] buf0, buf1;
    logic [1:0]  full;
    logic        wr_idx, rd_idx;

    logic [31:0] wbase;
    logic [31:0] tiles_left;    // tiles still to issue
    logic [31:0] tile;
    logic [7:0]  row;
    logic        rd_pending, rd_slot, rd_last;
    logic [7:0]  rd_row;

    // a slot MM is releasing this cycle refills at once: its last row was read
    // into MM's weight register this cycle, so N-cycle windows never starve
    logic [23:0] mm_tiles;
    assign mm_tiles = 24'(11'(insn[35:26]) + 11'd1) * 24'(13'(insn[47:36]) + 13'd1);

    logic issuing;
    assign issuing = tiles_left != 0 && (!full[wr_idx] || (slot_take && rd_idx == wr_idx));

    assign slot       = rd_idx ? buf1 : buf0;
    assign slot_full  = full[rd_idx];
    assign wmem_raddr = WMEM_AW'(tile * N + 32'(row));
    assign q_pop      = q_valid && tiles_left == 0 && !rd_pending
                        && (op != OP_WAIT || wait_met(insn[51:48], snap, completed));
    assign idle       = tiles_left == 0 && !rd_pending && !q_valid;

    always_ff @(posedge clk) begin
        if (reset) begin
            wbase      <= '0;
            tiles_left <= '0;
            tile       <= '0;
            row        <= '0;
            rd_pending <= 1'b0;
            rd_slot    <= 1'b0;
            rd_last    <= 1'b0;
            rd_row     <= '0;
            full       <= '0;
            wr_idx     <= 1'b0;
            rd_idx     <= 1'b0;
            done_pulse <= 1'b0;
            buf0       <= '0;
            buf1       <= '0;
        end else begin
            done_pulse <= 1'b0;

            if (q_pop) begin
                case (op)
                    OP_SET_WBASE: begin
                        wbase      <= insn[31:0];
                        done_pulse <= 1'b1;
                    end
                    OP_MATMUL: begin
                        tile       <= wbase;
                        tiles_left <= 32'(mm_tiles);
                        wbase      <= wbase + 32'(mm_tiles);
                        row        <= '0;
                    end
                    default: done_pulse <= 1'b1;   // WAIT
                endcase
            end

            // one row read per cycle; the slot index flips as the last row issues
            rd_pending <= issuing;
            rd_slot    <= wr_idx;
            rd_row     <= row;
            rd_last    <= issuing && row == 8'(N - 1) && tiles_left == 32'd1;
            if (issuing) begin
                if (row == 8'(N - 1)) begin
                    row        <= '0;
                    tile       <= tile + 32'd1;
                    tiles_left <= tiles_left - 32'd1;
                    wr_idx     <= !wr_idx;
                end else begin
                    row <= row + 8'd1;
                end
            end

            if (rd_pending) begin
                if (rd_slot) buf1[rd_row] <= wmem_rdata;
                else         buf0[rd_row] <= wmem_rdata;
                if (rd_row == 8'(N - 1)) begin
                    full[rd_slot] <= 1'b1;
                    if (rd_last)
                        done_pulse <= 1'b1;
                end
            end

            if (slot_take) begin
                full[rd_idx] <= 1'b0;
                rd_idx       <= !rd_idx;
            end
        end
    end

endmodule
