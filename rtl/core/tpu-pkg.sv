`timescale 1ns / 1ps

// instruction-set constants, mirrored in host/tpu/isa.py and isa_model.py
package tpu_pkg;

    localparam logic [5:0] OPCODE_NOP       = 6'h00;
    localparam logic [5:0] OPCODE_WR_WMEM   = 6'h01;
    localparam logic [5:0] OPCODE_WR_UB     = 6'h02;
    localparam logic [5:0] OPCODE_WR_BIAS   = 6'h03;
    localparam logic [5:0] OPCODE_WR_QUANT  = 6'h04;
    localparam logic [5:0] OPCODE_RD_DDR_UB = 6'h05;
    localparam logic [5:0] OPCODE_SET_WBASE = 6'h06;
    localparam logic [5:0] OPCODE_SET_OBASE = 6'h07;
    localparam logic [5:0] OPCODE_MATMUL    = 6'h10;
    localparam logic [5:0] OPCODE_ACTIVATE  = 6'h18;
    localparam logic [5:0] OPCODE_RD_UB     = 6'h19;
    localparam logic [5:0] OPCODE_WAIT      = 6'h20;
    localparam logic [5:0] OPCODE_SIGNAL    = 6'h21;

    // engines: WAIT's target field and on-mask bit positions
    localparam int ENGINE_LOAD     = 0;
    localparam int ENGINE_WEIGHT   = 1;
    localparam int ENGINE_MATMUL   = 2;
    localparam int ENGINE_ACTIVATE = 3;

    // decode errors, checked in this order
    localparam logic [7:0] ERROR_NONE          = 8'd0;
    localparam logic [7:0] ERROR_OPCODE        = 8'd1;
    localparam logic [7:0] ERROR_RESERVED      = 8'd2;
    localparam logic [7:0] ERROR_RANGE         = 8'd3;
    localparam logic [7:0] ERROR_COMBINATION   = 8'd4;
    localparam logic [7:0] ERROR_UNIMPLEMENTED = 8'd5;

    localparam logic [1:0] DESTINATION_UB   = 2'd0;
    localparam logic [1:0] DESTINATION_HOST = 2'd1;
    localparam logic [1:0] DESTINATION_DDR  = 2'd2;

    // bits each opcode may set, opcode included
    localparam logic [63:0] OPCODE_BITS       = 64'hFC00_0000_0000_0000;
    localparam logic [63:0] MASK_NOP          = OPCODE_BITS;
    localparam logic [63:0] MASK_WR_WMEM      = OPCODE_BITS | 64'h0000_FFFF_0000_FFFF;
    localparam logic [63:0] MASK_WR_UB        = OPCODE_BITS | 64'h0000_3FFF_0000_0FFF;
    localparam logic [63:0] MASK_WR_PARAMETER = OPCODE_BITS | 64'h0000_00FF_0000_00FF;
    localparam logic [63:0] MASK_RD_DDR_UB    = OPCODE_BITS | 64'h03FF_FFFF_FFFF_FFFF;
    localparam logic [63:0] MASK_SET_32_BIT   = OPCODE_BITS | 64'h0000_0000_FFFF_FFFF;
    localparam logic [63:0] MASK_MATMUL       = OPCODE_BITS | 64'h03FF_FFFF_FFFF_FFFC;
    localparam logic [63:0] MASK_ACTIVATE     = OPCODE_BITS | 64'h03FF_FFFF_FFFF_FFFC;
    localparam logic [63:0] MASK_WAIT         = OPCODE_BITS | 64'h030F_0000_0000_0000;
    localparam logic [63:0] MASK_SIGNAL       = OPCODE_BITS | 64'h0000_0000_0000_FFFF;

    // queue entry: the instruction, plus the dispatched-count snapshot a WAIT carries
    localparam int QUEUE_ENTRY_WIDTH = 128;

    // a WAIT at a queue head is satisfied once every masked engine's completed
    // count has caught up with the snapshot (modulo 2^16)
    function automatic logic wait_counts_reached(input logic [3:0] engine_mask, input logic [63:0] wait_snapshot,
                                      input logic [63:0] completed);
        logic satisfied;
        satisfied = 1'b1;
        for (int engine = 0; engine < 4; engine++)
            if (engine_mask[engine] && $signed(completed[16*engine +: 16] - wait_snapshot[16*engine +: 16]) < 0)
                satisfied = 1'b0;
        return satisfied;
    endfunction

endpackage
