`timescale 1ns / 1ps

// instruction-stream host bridge: 12-register Avalon-MM slave, read latency 1,
// waitrequest only on writes into a full FIFO
module isa_bridge (
    input  logic        clk,
    input  logic        reset,

    input  logic [3:0]  avs_address,      // word index
    input  logic        avs_read,
    output logic [31:0] avs_readdata,
    input  logic        avs_write,
    input  logic [31:0] avs_writedata,
    output logic        avs_waitrequest,

    output logic        insn_push,
    output logic [63:0] insn_word,
    input  logic        insn_full,
    output logic        data_push,
    output logic [31:0] data_word,
    input  logic        data_full,
    output logic        out_pop,
    input  logic [31:0] out_word,
    input  logic        out_empty,

    output logic        core_reset,       // CTRL.RESET: flush, clear ERR, memories kept
    output logic        clear_done,
    output logic        clear_perf,
    input  logic        done,
    input  logic        err,
    input  logic [7:0]  err_code,
    input  logic [31:0] err_seq,
    input  logic [15:0] tag,
    input  logic        idle,
    input  logic [9:0]  insn_free,
    input  logic [10:0] data_free,
    input  logic [10:0] out_count,
    input  logic [31:0] perf_cycles,
    input  logic [31:0] perf_mm_beats,
    input  logic [31:0] perf_mm_wstall,
    input  logic [31:0] perf_mm_sync
);

    localparam logic [3:0] A_INSN_LO = 4'd0,  A_INSN_HI = 4'd1,  A_DATA  = 4'd2,  A_OUT     = 4'd3;
    localparam logic [3:0] A_STATUS  = 4'd4,  A_LEVELS  = 4'd5,  A_CTRL  = 4'd6,  A_ERR_SEQ = 4'd7;
    localparam logic [3:0] A_CYCLES  = 4'd8,  A_BEATS   = 4'd9,  A_WSTALL = 4'd10, A_SYNC   = 4'd11;

    logic [31:0] insn_lo;
    logic        underflow;

    assign avs_waitrequest = avs_write && ((avs_address == A_INSN_HI && insn_full)
                                        || (avs_address == A_DATA && data_full));

    logic wr;
    assign wr = avs_write && !avs_waitrequest;

    assign insn_push  = wr && avs_address == A_INSN_HI;
    assign insn_word  = {avs_writedata, insn_lo};
    assign data_push  = wr && avs_address == A_DATA;
    assign data_word  = avs_writedata;
    assign out_pop    = avs_read && avs_address == A_OUT && !out_empty;
    assign core_reset = wr && avs_address == A_CTRL && avs_writedata[0];
    assign clear_done = wr && avs_address == A_CTRL && avs_writedata[1];
    assign clear_perf = wr && avs_address == A_CTRL && avs_writedata[2];

    always_ff @(posedge clk) begin
        if (reset) begin
            insn_lo      <= '0;
            underflow    <= 1'b0;
            avs_readdata <= '0;
        end else begin
            if (wr && avs_address == A_INSN_LO)
                insn_lo <= avs_writedata;
            if (core_reset || clear_done)
                underflow <= 1'b0;
            if (avs_read && avs_address == A_OUT && out_empty)
                underflow <= 1'b1;
            if (avs_read) begin
                case (avs_address)
                    A_OUT:     avs_readdata <= out_empty ? 32'd0 : out_word;
                    A_STATUS:  avs_readdata <= {tag, err_code, 4'd0, underflow, idle, err, done};
                    A_LEVELS:  avs_readdata <= {out_count, data_free, insn_free};
                    A_ERR_SEQ: avs_readdata <= err_seq;
                    A_CYCLES:  avs_readdata <= perf_cycles;
                    A_BEATS:   avs_readdata <= perf_mm_beats;
                    A_WSTALL:  avs_readdata <= perf_mm_wstall;
                    A_SYNC:    avs_readdata <= perf_mm_sync;
                    default:   avs_readdata <= 32'd0;
                endcase
            end
        end
    end

endmodule
