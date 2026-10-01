`timescale 1ns / 1ps

// instruction-set constants, mirrored in host/tpu/isa.py and isa_model.py
package tpu_pkg;

    localparam logic [5:0] OP_NOP       = 6'h00;
    localparam logic [5:0] OP_WR_WMEM   = 6'h01;
    localparam logic [5:0] OP_WR_UB     = 6'h02;
    localparam logic [5:0] OP_WR_BIAS   = 6'h03;
    localparam logic [5:0] OP_WR_QUANT  = 6'h04;
    localparam logic [5:0] OP_RD_DDR_UB = 6'h05;
    localparam logic [5:0] OP_SET_WBASE = 6'h06;
    localparam logic [5:0] OP_SET_OBASE = 6'h07;
    localparam logic [5:0] OP_MATMUL    = 6'h10;
    localparam logic [5:0] OP_ACTIVATE  = 6'h18;
    localparam logic [5:0] OP_RD_UB     = 6'h19;
    localparam logic [5:0] OP_WAIT      = 6'h20;
    localparam logic [5:0] OP_SIGNAL    = 6'h21;

    // engines: WAIT's target field and on-mask bit positions
    localparam int ENG_LD  = 0;
    localparam int ENG_WT  = 1;
    localparam int ENG_MM  = 2;
    localparam int ENG_ACT = 3;

    // decode errors, checked in this order
    localparam logic [7:0] ERR_NONE     = 8'd0;
    localparam logic [7:0] ERR_OPCODE   = 8'd1;
    localparam logic [7:0] ERR_RESERVED = 8'd2;
    localparam logic [7:0] ERR_RANGE    = 8'd3;
    localparam logic [7:0] ERR_COMBO    = 8'd4;
    localparam logic [7:0] ERR_UNIMPL   = 8'd5;

    localparam logic [1:0] DST_UB   = 2'd0;
    localparam logic [1:0] DST_HOST = 2'd1;
    localparam logic [1:0] DST_DDR  = 2'd2;

    // bits each opcode may set, opcode included
    localparam logic [63:0] OPC_BITS    = 64'hFC00_0000_0000_0000;
    localparam logic [63:0] MASK_NOP    = OPC_BITS;
    localparam logic [63:0] MASK_WR_WMEM = OPC_BITS | 64'h0000_FFFF_0000_FFFF;
    localparam logic [63:0] MASK_WR_UB  = OPC_BITS | 64'h0000_3FFF_0000_0FFF;
    localparam logic [63:0] MASK_WR_PAR = OPC_BITS | 64'h0000_00FF_0000_00FF;
    localparam logic [63:0] MASK_RD_DDR = OPC_BITS | 64'h03FF_FFFF_FFFF_FFFF;
    localparam logic [63:0] MASK_SET32  = OPC_BITS | 64'h0000_0000_FFFF_FFFF;
    localparam logic [63:0] MASK_MATMUL = OPC_BITS | 64'h03FF_FFFF_FFFF_FFFC;
    localparam logic [63:0] MASK_ACT    = OPC_BITS | 64'h03FF_FFFF_FFFF_FFFC;
    localparam logic [63:0] MASK_WAIT   = OPC_BITS | 64'h030F_0000_0000_0000;
    localparam logic [63:0] MASK_SIGNAL = OPC_BITS | 64'h0000_0000_0000_FFFF;

    // queue entry: the instruction, plus the dispatched-count snapshot a WAIT carries
    localparam int UOP_W = 128;

    // a WAIT at a queue head is satisfied once every masked engine's completed
    // count has caught up with the snapshot (modulo 2^16)
    function automatic logic wait_met(input logic [3:0] mask, input logic [63:0] snap,
                                      input logic [63:0] completed);
        logic ok;
        ok = 1'b1;
        for (int e = 0; e < 4; e++)
            if (mask[e] && $signed(completed[16*e +: 16] - snap[16*e +: 16]) < 0)
                ok = 1'b0;
        return ok;
    endfunction

endpackage
