`timescale 1ns / 1ps

import isa_pkg::*;

// MM engine: drives the systolic array serially (phase 1) and accumulates into ACC.
// per tile: copy the slot into weight_fifo bottom row first, gap, swap, load,
// stream m UB rows, then drain before the next tile
module isa_mm #(
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

    input  logic [N-1:0][N*8-1:0] slot,
    input  logic                  slot_full,
    output logic                  slot_take,

    output logic                  ub_re,           // always granted
    output logic [UB_AW-1:0]      ub_raddr,
    input  logic [N*8-1:0]        ub_rdata,

    output logic                  acc_re,          // always granted
    output logic [ACC_AW-1:0]     acc_raddr,
    input  logic [N*32-1:0]       acc_rdata,
    output logic                  acc_we,
    output logic [ACC_AW-1:0]     acc_waddr,
    output logic [N*32-1:0]       acc_wdata,

    output logic                  perf_beat,
    output logic                  perf_wstall,
    output logic                  perf_sync,
    output logic                  idle
);

    localparam int SKEW_DEPTH = (2 * N <= 4) ? 4 : (2 * N <= 8) ? 8 : (2 * N <= 16) ? 16 : (2 * N <= 32) ? 32 : 64;
    localparam int TAG_DEPTH  = 64;

    logic [63:0] insn, snap;
    assign insn = q_data[63:0];
    assign snap = q_data[127:64];
    logic [5:0] op;
    assign op = insn[63:58];

    typedef enum logic [2:0] {S_IDLE, S_WAIT_TILE, S_LOADW, S_GAP, S_SWAP, S_LOADING, S_STREAM, S_DRAIN} state_t;
    state_t state;

    logic        acc_flag;
    logic [8:0]  m;
    logic [12:0] kt, k;
    logic [10:0] nb, b;
    logic [15:0] chunk_base, ub_base;
    logic [15:0] acc_base;
    logic [8:0]  cnt;
    logic [8:0]  rows_written;

    // -- array ------------------------------------------------------------
    logic                         wf_we_any;
    logic [7:0]                   wf_row;
    logic signed [N-1:0][7:0]     wf_wdata;
    logic                         swap_banks, loading_phase;
    logic signed [N-1:0][7:0]     wf_col;
    logic        [N-1:0]          wf_col_valid;

    always_comb
        for (int c = 0; c < N; c++)
            wf_wdata[c] = slot[wf_row][8*c +: 8];

    weight_fifo #(.WEIGHT_WIDTH(8), .FIFO_DEPTH(SKEW_DEPTH), .NUM_COLS(N)) u_wf (
        .clk(clk), .reset(reset),
        .write_enable_col({N{wf_we_any}}), .write_data_col(wf_wdata),
        .swap_banks(swap_banks), .loading_phase(loading_phase),
        .out_col(wf_col), .out_col_valid(wf_col_valid),
        .shadow_loaded(), .active_bank(), .active_empty(), .active_full(), .any_shadow_full()
    );

    logic                         ub_valid_q;
    logic signed [N-1:0][7:0]     sds_in;
    logic signed [N-1:0][7:0]     skewed;
    logic        [N-1:0]          skewed_valid;

    assign sds_in = ub_rdata;

    systolic_data_setup #(.ARRAY_ROWS(N), .DATA_WIDTH(8)) u_sds (
        .clk(clk), .reset(reset),
        .ub_read_data(sds_in), .ub_read_valid(ub_valid_q),
        .mmu_in_row(skewed), .mmu_in_valid(skewed_valid)
    );

    logic signed [N-1:0][31:0] psum;
    logic        [N-1:0]       psum_valid;

    mmu #(.ARRAY_ROWS(N), .NUM_COLS(N), .DATA_WIDTH(8), .PSUM_WIDTH(32), .USE_MAC16_PAIR(0)) u_mmu (
        .clk(clk), .reset(reset), .loading_phase(loading_phase),
        .capture_weight_col(wf_col_valid), .in_col(wf_col), .in_col_valid(wf_col_valid),
        .in_row(skewed), .in_row_valid(skewed_valid),
        .out_partial_sum(psum), .out_partial_sum_valid(psum_valid)
    );

    // -- column re-alignment + row tags -------------------------------------
    logic [N-1:0]              col_empty;
    logic signed [N-1:0][31:0] col_head;
    logic                      row_pop;

    genvar gc;
    generate
        for (gc = 0; gc < N; gc++) begin : g_col
            fifo #(.WIDTH(32), .DEPTH(SKEW_DEPTH)) u_col (
                .clk(clk), .reset(reset),
                .write_enable(psum_valid[gc]), .write_data(psum[gc]),
                .read_enable(row_pop), .read_data(col_head[gc]),
                .full(), .empty(col_empty[gc])
            );
        end
    endgenerate

    logic                tag_push, tag_empty;
    logic [ACC_AW:0]     tag_in, tag_head;     // {overwrite, acc_row}

    fifo #(.WIDTH(ACC_AW + 1), .DEPTH(TAG_DEPTH)) u_tags (
        .clk(clk), .reset(reset),
        .write_enable(tag_push), .write_data(tag_in),
        .read_enable(row_pop), .read_data(tag_head),
        .full(), .empty(tag_empty)
    );

    assign row_pop = (col_empty == '0) && !tag_empty;

    // read-modify-write: read at pop, add and write back the next cycle.
    // rows of one tile are distinct, and tiles are serialized, so no forwarding
    logic                  s1_valid, s1_ow;
    logic [ACC_AW-1:0]     s1_addr;
    logic [N*32-1:0]       s1_psum;

    assign acc_re    = row_pop && !tag_head[ACC_AW];
    assign acc_raddr = tag_head[ACC_AW-1:0];
    assign acc_we    = s1_valid;
    assign acc_waddr = s1_addr;
    always_comb
        for (int c = 0; c < N; c++)
            acc_wdata[32*c +: 32] = s1_ow ? s1_psum[32*c +: 32] : acc_rdata[32*c +: 32] + s1_psum[32*c +: 32];

    // -- control -----------------------------------------------------------
    logic stream_now;
    assign stream_now = (state == S_STREAM);
    assign ub_re      = stream_now;
    assign ub_raddr   = UB_AW'(chunk_base + 16'(cnt));
    assign tag_push   = stream_now;
    assign tag_in     = {(k == 13'd0) && !acc_flag, ACC_AW'(acc_base + 16'(cnt))};

    assign wf_we_any     = (state == S_LOADW);
    assign wf_row        = 8'(N - 1) - 8'(cnt);            // bottom row first
    assign slot_take     = (state == S_LOADW) && cnt == 9'(N - 1);
    assign swap_banks    = (state == S_SWAP);
    assign loading_phase = (state == S_LOADING);

    logic wait_ok;
    assign wait_ok = wait_met(insn[51:48], snap, completed);
    assign q_pop   = q_valid && state == S_IDLE && (op != OP_WAIT || wait_ok);
    assign idle    = state == S_IDLE && !q_valid;

    assign perf_beat   = stream_now;
    assign perf_wstall = (state == S_WAIT_TILE) && !slot_full;
    assign perf_sync   = q_valid && state == S_IDLE && op == OP_WAIT && !wait_ok;

    always_ff @(posedge clk) begin
        if (reset) begin
            state        <= S_IDLE;
            acc_flag     <= 1'b0;
            m            <= '0;
            kt           <= '0;
            k            <= '0;
            nb           <= '0;
            b            <= '0;
            chunk_base   <= '0;
            ub_base      <= '0;
            acc_base     <= '0;
            cnt          <= '0;
            rows_written <= '0;
            ub_valid_q   <= 1'b0;
            s1_valid     <= 1'b0;
            s1_ow        <= 1'b0;
            s1_addr      <= '0;
            s1_psum      <= '0;
            done_pulse   <= 1'b0;
        end else begin
            done_pulse <= 1'b0;
            ub_valid_q <= ub_re;

            s1_valid <= row_pop;
            s1_ow    <= tag_head[ACC_AW];
            s1_addr  <= tag_head[ACC_AW-1:0];
            s1_psum  <= col_head;
            if (s1_valid)
                rows_written <= rows_written + 9'd1;

            case (state)
                S_IDLE: if (q_pop) begin
                    if (op == OP_MATMUL) begin
                        acc_flag   <= insn[57];
                        m          <= 9'(insn[55:48]) + 9'd1;
                        kt         <= 13'(insn[47:36]) + 13'd1;
                        nb         <= 11'(insn[35:26]) + 11'd1;
                        acc_base   <= 16'(insn[25:16]);
                        ub_base    <= 16'(insn[15:2]);
                        chunk_base <= 16'(insn[15:2]);
                        k          <= '0;
                        b          <= '0;
                        state      <= S_WAIT_TILE;
                    end else begin
                        done_pulse <= 1'b1;            // WAIT
                    end
                end
                S_WAIT_TILE: if (slot_full) begin
                    cnt   <= '0;
                    state <= S_LOADW;
                end
                S_LOADW: begin
                    if (cnt == 9'(N - 1)) begin
                        cnt   <= '0;
                        state <= S_GAP;
                    end else begin
                        cnt <= cnt + 9'd1;
                    end
                end
                S_GAP:  state <= S_SWAP;
                S_SWAP: state <= S_LOADING;
                S_LOADING: begin                       // N drain cycles + 1 guard
                    if (cnt == 9'(N)) begin
                        cnt          <= '0;
                        rows_written <= '0;
                        state        <= S_STREAM;
                    end else begin
                        cnt <= cnt + 9'd1;
                    end
                end
                S_STREAM: begin
                    if (cnt == m - 9'd1) begin
                        cnt   <= '0;
                        state <= S_DRAIN;
                    end else begin
                        cnt <= cnt + 9'd1;
                    end
                end
                S_DRAIN: if (rows_written == m) begin
                    if (k == kt - 13'd1) begin
                        k          <= '0;
                        chunk_base <= ub_base;
                        acc_base   <= acc_base + 16'(m);
                        if (b == nb - 11'd1) begin
                            done_pulse <= 1'b1;
                            state      <= S_IDLE;
                        end else begin
                            b     <= b + 11'd1;
                            state <= S_WAIT_TILE;
                        end
                    end else begin
                        k          <= k + 13'd1;
                        chunk_base <= chunk_base + 16'(m);
                        state      <= S_WAIT_TILE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
