`timescale 1ns / 1ps

import isa_pkg::*;

// instruction-stream core: host FIFOs, dispatcher, four engines and their memories.
// board-neutral; a bridge in front of it speaks the host bus
module isa_core #(
    parameter int N           = 8,
    parameter int WMEM_ROWS   = 8192,
    parameter int UB_DEPTH    = 16384,
    parameter int ACC_DEPTH   = 1024,
    parameter int PARAM_DEPTH = 256,
    parameter int IFIFO_DEPTH = 512,
    parameter int DFIFO_DEPTH = 1024,
    parameter int OFIFO_DEPTH = 1024,
    parameter int QDEPTH      = 8
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        insn_push,
    input  logic [63:0] insn_word,
    output logic        insn_full,
    input  logic        data_push,
    input  logic [31:0] data_word,
    output logic        data_full,
    input  logic        out_pop,
    output logic [31:0] out_word,
    output logic        out_empty,

    input  logic        clear_done,
    input  logic        clear_perf,
    output logic        done,
    output logic        err,
    output logic [7:0]  err_code,
    output logic [31:0] err_seq,
    output logic [15:0] tag,
    output logic        idle,
    output logic [9:0]  insn_free,
    output logic [10:0] data_free,
    output logic [10:0] out_count,
    output logic [31:0] perf_cycles,
    output logic [31:0] perf_mm_beats,
    output logic [31:0] perf_mm_wstall,
    output logic [31:0] perf_mm_sync
);

    initial begin
        if (N % 4 != 0) $fatal(1, "isa_core: N=%0d must be a multiple of 4", N);
    end

    localparam int WMEM_AW = $clog2(WMEM_ROWS);
    localparam int UB_AW   = $clog2(UB_DEPTH);
    localparam int ACC_AW  = $clog2(ACC_DEPTH);
    localparam int PAR_AW  = $clog2(PARAM_DEPTH);

    // -- host FIFOs, with occupancy counts for LEVELS ------------------------
    logic        insn_empty;
    logic [63:0] insn_head;
    logic        insn_pop;
    logic        data_empty, data_pop;
    logic [31:0] data_head;
    logic        out_push, out_full;
    logic [31:0] out_in;

    fifo #(.WIDTH(64), .DEPTH(IFIFO_DEPTH)) u_ififo (
        .clk(clk), .reset(reset), .write_enable(insn_push), .write_data(insn_word),
        .read_enable(insn_pop), .read_data(insn_head), .full(insn_full), .empty(insn_empty));
    fifo #(.WIDTH(32), .DEPTH(DFIFO_DEPTH)) u_dfifo (
        .clk(clk), .reset(reset), .write_enable(data_push), .write_data(data_word),
        .read_enable(data_pop), .read_data(data_head), .full(data_full), .empty(data_empty));
    fifo #(.WIDTH(32), .DEPTH(OFIFO_DEPTH)) u_ofifo (
        .clk(clk), .reset(reset), .write_enable(out_push), .write_data(out_in),
        .read_enable(out_pop), .read_data(out_word), .full(out_full), .empty(out_empty));

    logic [10:0] insn_cnt, data_cnt, out_cnt;
    always_ff @(posedge clk) begin
        if (reset) begin
            insn_cnt <= '0; data_cnt <= '0; out_cnt <= '0;
        end else begin
            insn_cnt <= insn_cnt + 11'(insn_push && !insn_full) - 11'(insn_pop && !insn_empty);
            data_cnt <= data_cnt + 11'(data_push && !data_full) - 11'(data_pop && !data_empty);
            out_cnt  <= out_cnt + 11'(out_push && !out_full) - 11'(out_pop && !out_empty);
        end
    end
    assign insn_free = 10'(11'(IFIFO_DEPTH) - insn_cnt);
    assign data_free = 11'(DFIFO_DEPTH) - data_cnt;
    assign out_count = out_cnt;

    // -- dispatcher + engine queues --------------------------------------------
    logic [3:0]           q_push, q_full, q_empty, q_pop;
    logic [UOP_W-1:0]     q_in;
    logic [UOP_W-1:0]     q_head [4];
    logic [63:0]          dispatched, completed;
    logic [3:0]           done_pulse;
    logic                 fence_busy;

    isa_dispatch #(.N(N), .WMEM_ROWS(WMEM_ROWS), .UB_DEPTH(UB_DEPTH), .ACC_DEPTH(ACC_DEPTH),
                   .PARAM_DEPTH(PARAM_DEPTH)) u_dispatch (
        .clk(clk), .reset(reset),
        .insn_valid(!insn_empty), .insn(insn_head), .insn_pop(insn_pop),
        .q_push(q_push), .q_data(q_in), .q_full(q_full),
        .completed(completed), .dispatched(dispatched),
        .err(err), .err_code(err_code), .err_seq(err_seq),
        .done(done), .tag(tag), .clear_done(clear_done), .busy(fence_busy));

    genvar ge;
    generate
        for (ge = 0; ge < 4; ge++) begin : g_q
            fifo #(.WIDTH(UOP_W), .DEPTH(QDEPTH)) u_q (
                .clk(clk), .reset(reset), .write_enable(q_push[ge]), .write_data(q_in),
                .read_enable(q_pop[ge]), .read_data(q_head[ge]),
                .full(q_full[ge]), .empty(q_empty[ge]));
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (reset) completed <= '0;
        else for (int e = 0; e < 4; e++)
            if (done_pulse[e]) completed[16*e +: 16] <= completed[16*e +: 16] + 16'd1;
    end

    // -- memories (registered reads, so they can map to block RAM) -------------
    logic [N*8-1:0]  wmem [WMEM_ROWS];
    logic [N*8-1:0]  ub   [UB_DEPTH];
    logic [N*32-1:0] acc  [ACC_DEPTH];
    logic [N*32-1:0] bias_tab  [PARAM_DEPTH];
    logic [N*32-1:0] quant_tab [PARAM_DEPTH];

    logic                wmem_we, ub_we, bias_we, quant_we;
    logic [WMEM_AW-1:0]  wmem_waddr, wmem_raddr;
    logic [UB_AW-1:0]    ub_waddr;
    logic [N*8-1:0]      ld_row;
    logic [PAR_AW-1:0]   par_waddr, bias_raddr;
    logic [N*32-1:0]     par_wdata;
    logic [N*8-1:0]      wmem_rdata, ub_rdata;
    logic [N*32-1:0]     acc_rdata, bias_rdata, quant_rdata;
    logic                act_ub_we;
    logic [UB_AW-1:0]    act_ub_waddr;
    logic [N*8-1:0]      act_ub_wdata;

    logic                mm_ub_re, act_ub_re, mm_acc_re, act_acc_re, acc_we;
    logic [UB_AW-1:0]    mm_ub_raddr, act_ub_raddr;
    logic [ACC_AW-1:0]   mm_acc_raddr, act_acc_raddr, acc_waddr;
    logic [N*32-1:0]     acc_wdata;

    always_ff @(posedge clk) begin
        if (wmem_we)  wmem[wmem_waddr]     <= ld_row;
        if (act_ub_we)  ub[act_ub_waddr]   <= act_ub_wdata;   // ACT has the write port first
        else if (ub_we) ub[ub_waddr]       <= ld_row;
        if (bias_we)  bias_tab[par_waddr]  <= par_wdata;
        if (quant_we) quant_tab[par_waddr] <= par_wdata;
        if (acc_we)   acc[acc_waddr]       <= acc_wdata;
        wmem_rdata <= wmem[wmem_raddr];
        ub_rdata   <= ub[mm_ub_re ? mm_ub_raddr : act_ub_raddr];
        acc_rdata  <= acc[mm_acc_re ? mm_acc_raddr : act_acc_raddr];
        bias_rdata <= bias_tab[bias_raddr];
        quant_rdata <= quant_tab[bias_raddr];
    end

    // -- engines ---------------------------------------------------------------
    logic [N-1:0][N*8-1:0] slot;
    logic                  slot_full, slot_take;
    logic [3:0]            eng_idle;
    logic                  perf_beat, perf_wstall, perf_sync;

    isa_ld #(.N(N), .WMEM_AW(WMEM_AW), .UB_AW(UB_AW), .PAR_AW(PAR_AW)) u_ld (
        .clk(clk), .reset(reset),
        .q_valid(!q_empty[ENG_LD]), .q_data(q_head[ENG_LD]), .q_pop(q_pop[ENG_LD]),
        .completed(completed), .done_pulse(done_pulse[ENG_LD]),
        .data_valid(!data_empty), .ub_wbusy(act_ub_we), .data(data_head), .data_pop(data_pop),
        .wmem_we(wmem_we), .wmem_waddr(wmem_waddr), .ub_we(ub_we), .ub_waddr(ub_waddr),
        .row_wdata(ld_row), .bias_we(bias_we), .quant_we(quant_we),
        .par_waddr(par_waddr), .par_wdata(par_wdata), .idle(eng_idle[ENG_LD]));

    isa_wt #(.N(N), .WMEM_AW(WMEM_AW)) u_wt (
        .clk(clk), .reset(reset),
        .q_valid(!q_empty[ENG_WT]), .q_data(q_head[ENG_WT]), .q_pop(q_pop[ENG_WT]),
        .completed(completed), .done_pulse(done_pulse[ENG_WT]),
        .wmem_raddr(wmem_raddr), .wmem_rdata(wmem_rdata),
        .slot(slot), .slot_full(slot_full), .slot_take(slot_take), .idle(eng_idle[ENG_WT]));

    isa_mm #(.N(N), .UB_AW(UB_AW), .ACC_AW(ACC_AW)) u_mm (
        .clk(clk), .reset(reset),
        .q_valid(!q_empty[ENG_MM]), .q_data(q_head[ENG_MM]), .q_pop(q_pop[ENG_MM]),
        .completed(completed), .done_pulse(done_pulse[ENG_MM]),
        .slot(slot), .slot_full(slot_full), .slot_take(slot_take),
        .ub_re(mm_ub_re), .ub_raddr(mm_ub_raddr), .ub_rdata(ub_rdata),
        .acc_re(mm_acc_re), .acc_raddr(mm_acc_raddr), .acc_rdata(acc_rdata),
        .acc_we(acc_we), .acc_waddr(acc_waddr), .acc_wdata(acc_wdata),
        .perf_beat(perf_beat), .perf_wstall(perf_wstall), .perf_sync(perf_sync),
        .idle(eng_idle[ENG_MM]));

    isa_act #(.N(N), .UB_AW(UB_AW), .ACC_AW(ACC_AW), .PAR_AW(PAR_AW)) u_act (
        .clk(clk), .reset(reset),
        .q_valid(!q_empty[ENG_ACT]), .q_data(q_head[ENG_ACT]), .q_pop(q_pop[ENG_ACT]),
        .completed(completed), .done_pulse(done_pulse[ENG_ACT]),
        .acc_re(act_acc_re), .acc_raddr(act_acc_raddr), .acc_busy(mm_acc_re), .acc_rdata(acc_rdata),
        .bias_raddr(bias_raddr), .bias_rdata(bias_rdata), .quant_rdata(quant_rdata),
        .ub_we(act_ub_we), .ub_waddr(act_ub_waddr), .ub_wdata(act_ub_wdata),
        .ub_re(act_ub_re), .ub_raddr(act_ub_raddr), .ub_busy(mm_ub_re), .ub_rdata(ub_rdata),
        .out_push(out_push), .out_word(out_in), .out_full(out_full), .idle(eng_idle[ENG_ACT]));

    assign idle = insn_empty && eng_idle == 4'hF && !fence_busy;

    // -- performance counters --------------------------------------------------
    always_ff @(posedge clk) begin
        if (reset || clear_perf) begin
            perf_cycles <= '0; perf_mm_beats <= '0; perf_mm_wstall <= '0; perf_mm_sync <= '0;
        end else begin
            perf_cycles    <= perf_cycles + 32'd1;
            perf_mm_beats  <= perf_mm_beats + 32'(perf_beat);
            perf_mm_wstall <= perf_mm_wstall + 32'(perf_wstall);
            perf_mm_sync   <= perf_mm_sync + 32'(perf_sync);
        end
    end

endmodule
