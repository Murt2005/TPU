`timescale 1ns / 1ps

import tpu_pkg::*;

// WT engine: SET_WBASE, and the weight half of MATMUL: WMEM tiles into the weight
// FIFO's slots, one row read per cycle, back to back across tiles while a slot is free
module wt_engine #(
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

    input  logic                 fill_ready,     // weight_fifo
    input  logic                 fill_slot_next,
    output logic                 fill_advance,
    output logic                 fill_we,
    output logic                 fill_slot,
    output logic [7:0]           fill_row,
    output logic [N*8-1:0]       fill_data,

    output logic                 idle
);

    logic [63:0] insn, snap;
    assign insn = q_data[63:0];
    assign snap = q_data[127:64];
    logic [5:0] op;
    assign op = insn[63:58];

    logic [31:0] wbase;
    logic [31:0] tiles_left;    // tiles still to issue
    logic [31:0] tile;
    logic [7:0]  row;
    logic        rd_pending, rd_slot, rd_last;
    logic [7:0]  rd_row;

    logic [23:0] mm_tiles;
    assign mm_tiles = 24'(11'(insn[35:26]) + 11'd1) * 24'(13'(insn[47:36]) + 13'd1);

    logic issuing;
    assign issuing = tiles_left != 0 && fill_ready;

    assign fill_advance = issuing && row == 8'(N - 1);
    assign fill_we      = rd_pending;
    assign fill_slot    = rd_slot;
    assign fill_row     = rd_row;
    assign fill_data    = wmem_rdata;

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
            done_pulse <= 1'b0;
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
            rd_slot    <= fill_slot_next;
            rd_row     <= row;
            rd_last    <= issuing && row == 8'(N - 1) && tiles_left == 32'd1;
            if (issuing) begin
                if (row == 8'(N - 1)) begin
                    row        <= '0;
                    tile       <= tile + 32'd1;
                    tiles_left <= tiles_left - 32'd1;
                end else begin
                    row <= row + 8'd1;
                end
            end

            if (rd_pending && rd_row == 8'(N - 1) && rd_last)
                done_pulse <= 1'b1;
        end
    end

endmodule
