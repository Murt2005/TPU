`timescale 1ns / 1ps

import tpu_pkg::*;

// MM engine: overlapped tiles. each window of max(m, N) cycles streams one tile's
// m activation rows and, in its last N cycles, the next tile's weight rows into
// w_next; the next tile's first row flips them in. a missing tile freezes the
// whole window (WSTALL), which only ever widens the gaps the PEs rely on.
// control only: tpu_core wires the UB, systolic data setup, mmu and accumulator
module mm_engine #(
    parameter int N      = 8,
    parameter int UB_AW  = 14,
    parameter int ACC_AW = 10
) (
    input  logic                  clk,
    input  logic                  reset,

    input  logic                  q_valid,
    input  logic [UOP_W-1:0]      q_data,
    output logic                  q_pop,
    input  logic [63:0]           completed,
    output logic                  done_pulse,

    input  logic [N-1:0][N*8-1:0] tile,            // weight_fifo
    input  logic                  tile_full,
    output logic                  tile_take,

    output logic                  ub_re,           // always granted
    output logic [UB_AW-1:0]      ub_raddr,
    output logic                  act_valid,       // the UB row read last cycle goes in now
    output logic                  act_first,       // ... and it's a tile's first row: flip

    output logic                  wvalid,          // the next tile's weight row, onto the
    output logic [$clog2(N)-1:0]  wrow,            // mmu's row-select bus
    output logic signed [N-1:0][7:0] wdata,

    output logic                  tag_push,        // accumulator: where each issued row goes
    output logic [ACC_AW:0]       tag_in,
    input  logic                  row_written,

    output logic                  perf_beat,
    output logic                  perf_wstall,
    output logic                  perf_sync,
    output logic                  idle
);

    localparam int RW = $clog2(N);

    logic [63:0] insn, snap;
    assign insn = q_data[63:0];
    assign snap = q_data[127:64];
    logic [5:0] op;
    assign op = insn[63:58];

    typedef enum logic [1:0] {S_IDLE, S_RUN, S_DRAIN} state_t;
    state_t state;

    logic        acc_flag;
    logic [8:0]  m;
    logic [12:0] kt, k;
    logic [15:0] chunk_base, ub_base;
    logic [15:0] acc_base;
    logic        have_acts, have_wts;     // this window streams a tile / loads the next
    logic [31:0] wt_left;                 // tiles whose weights are still to load
    logic [8:0]  pos;
    logic [7:0]  inflight;                // rows issued, not yet written to ACC

    logic [8:0] len, w_start;
    assign len     = (have_acts && m > 9'(N)) ? m : 9'(N);
    assign w_start = len - 9'(N);

    logic act_now, wt_now, freeze, go, win_end;
    assign act_now = have_acts && pos < m;
    assign wt_now  = have_wts && pos >= w_start;
    assign freeze  = wt_now && !tile_full;
    assign go      = state == S_RUN && !freeze;
    assign win_end = go && pos == len - 9'd1;

    logic                     ub_valid_q, first_q;
    logic                     wreg_valid;
    logic [RW-1:0]            wreg_row;
    logic signed [N-1:0][7:0] wreg_data;
    logic [RW-1:0]            wrow_now;
    assign wrow_now  = RW'(pos - w_start);
    assign act_valid = ub_valid_q;
    assign act_first = first_q;
    assign wvalid    = wreg_valid;
    assign wrow      = wreg_row;
    assign wdata     = wreg_data;

    // -- control -----------------------------------------------------------
    assign ub_re     = go && act_now;
    assign ub_raddr  = UB_AW'(chunk_base + 16'(pos));
    assign tag_push  = ub_re;
    assign tag_in    = {(k == 13'd0) && !acc_flag, ACC_AW'(acc_base + 16'(pos))};
    assign tile_take = go && wt_now && pos == len - 9'd1;

    logic wait_ok;
    assign wait_ok = wait_met(insn[51:48], snap, completed);
    assign q_pop   = q_valid && state == S_IDLE && (op != OP_WAIT || wait_ok);
    assign idle    = state == S_IDLE && !q_valid;

    assign perf_beat   = ub_re;
    assign perf_wstall = state == S_RUN && freeze;
    assign perf_sync   = q_valid && state == S_IDLE && op == OP_WAIT && !wait_ok;

    always_ff @(posedge clk) begin
        if (reset) begin
            state      <= S_IDLE;
            acc_flag   <= 1'b0;
            m          <= '0;
            kt         <= '0;
            k          <= '0;
            chunk_base <= '0;
            ub_base    <= '0;
            acc_base   <= '0;
            have_acts  <= 1'b0;
            have_wts   <= 1'b0;
            wt_left    <= '0;
            pos        <= '0;
            inflight   <= '0;
            ub_valid_q <= 1'b0;
            first_q    <= 1'b0;
            wreg_valid <= 1'b0;
            wreg_row   <= '0;
            wreg_data  <= '0;
            done_pulse <= 1'b0;
        end else begin
            done_pulse <= 1'b0;
            ub_valid_q <= ub_re;
            first_q    <= pos == 9'd0;

            // weight row registered to line up with the UB read latency
            wreg_valid <= go && wt_now;
            wreg_row   <= wrow_now;
            for (int c = 0; c < N; c++)
                wreg_data[c] <= tile[wrow_now][8*c +: 8];

            inflight <= inflight + 8'(tag_push) - 8'(row_written);

            case (state)
                S_IDLE: if (q_pop) begin
                    if (op == OP_MATMUL) begin
                        acc_flag   <= insn[57];
                        m          <= 9'(insn[55:48]) + 9'd1;
                        kt         <= 13'(insn[47:36]) + 13'd1;
                        acc_base   <= 16'(insn[25:16]);
                        ub_base    <= 16'(insn[15:2]);
                        chunk_base <= 16'(insn[15:2]);
                        k          <= '0;
                        have_acts  <= 1'b0;
                        have_wts   <= 1'b1;
                        wt_left    <= 32'(24'(11'(insn[35:26]) + 11'd1) * 24'(13'(insn[47:36]) + 13'd1));
                        pos        <= '0;
                        state      <= S_RUN;
                    end else begin
                        done_pulse <= 1'b1;            // WAIT
                    end
                end
                S_RUN: if (go) begin
                    pos <= pos + 9'd1;
                    if (win_end) begin
                        pos <= '0;
                        if (have_acts) begin
                            if (k == kt - 13'd1) begin
                                k          <= '0;
                                chunk_base <= ub_base;
                                acc_base   <= acc_base + 16'(m);
                            end else begin
                                k          <= k + 13'd1;
                                chunk_base <= chunk_base + 16'(m);
                            end
                        end
                        have_acts <= have_wts;
                        if (have_wts)
                            wt_left <= wt_left - 32'd1;
                        have_wts <= have_wts && wt_left > 32'd1;
                        if (!have_wts)
                            state <= S_DRAIN;
                    end
                end
                S_DRAIN: if (inflight == 8'd0) begin
                    done_pulse <= 1'b1;
                    state      <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
