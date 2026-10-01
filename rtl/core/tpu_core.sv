`timescale 1ns / 1ps

import tpu_pkg::*;

// the TPU core: host FIFOs, the dispatcher and four engines (control), around the
// TPUv1 datapath: unified buffer -> systolic data setup -> mmu -> accumulators ->
// bias -> activation, with weights from WMEM through the weight FIFO.
// board-neutral; a bridge in front of it speaks the host bus
module tpu_core #(
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
        if (N % 4 != 0) $fatal(1, "tpu_core: N=%0d must be a multiple of 4", N);
    end

    localparam int WMEM_AW = $clog2(WMEM_ROWS);
    localparam int UB_AW   = $clog2(UB_DEPTH);
    localparam int ACC_AW  = $clog2(ACC_DEPTH);
    localparam int PAR_AW  = $clog2(PARAM_DEPTH);
    localparam int RW      = $clog2(N);

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

    dispatch #(.N(N), .WMEM_ROWS(WMEM_ROWS), .UB_DEPTH(UB_DEPTH), .ACC_DEPTH(ACC_DEPTH),
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

    // -- WMEM and the parameter tables (registered reads, so they map to block RAM)
    logic [N*8-1:0]  wmem [WMEM_ROWS];
    logic [N*32-1:0] bias_tab  [PARAM_DEPTH];
    logic [N*32-1:0] quant_tab [PARAM_DEPTH];

    logic                wmem_we, ub_we, bias_we, quant_we;
    logic [WMEM_AW-1:0]  wmem_waddr, wmem_raddr;
    logic [UB_AW-1:0]    ub_waddr;
    logic [N*8-1:0]      ld_row;
    logic [PAR_AW-1:0]   par_waddr, par_raddr;
    logic [N*32-1:0]     par_wdata;
    logic [N*8-1:0]      wmem_rdata;
    logic [N*32-1:0]     bias_rdata, quant_rdata;

    always_ff @(posedge clk) begin
        if (wmem_we)  wmem[wmem_waddr]     <= ld_row;
        if (bias_we)  bias_tab[par_waddr]  <= par_wdata;
        if (quant_we) quant_tab[par_waddr] <= par_wdata;
        wmem_rdata  <= wmem[wmem_raddr];
        bias_rdata  <= bias_tab[par_raddr];
        quant_rdata <= quant_tab[par_raddr];
    end

    // -- unified buffer ----------------------------------------------------------
    logic                mm_ub_re, act_ub_re, act_ub_we;
    logic [UB_AW-1:0]    mm_ub_raddr, act_ub_raddr, act_ub_waddr;
    logic [N*8-1:0]      act_ub_wdata, ub_rdata;

    unified_buffer #(.N(N), .DEPTH(UB_DEPTH)) u_ub (
        .clk(clk),
        .ld_we(ub_we), .ld_waddr(ub_waddr), .ld_wdata(ld_row),
        .act_we(act_ub_we), .act_waddr(act_ub_waddr), .act_wdata(act_ub_wdata),
        .mm_re(mm_ub_re), .mm_raddr(mm_ub_raddr), .act_raddr(act_ub_raddr),
        .rdata(ub_rdata));

    // -- weight FIFO: WT fills, MM drains ------------------------------------------
    logic                  fill_ready, fill_slot_next, fill_advance, fill_we, fill_slot;
    logic [7:0]            fill_row;
    logic [N*8-1:0]        fill_data;
    logic [N-1:0][N*8-1:0] tile;
    logic                  tile_full, tile_take;

    weight_fifo #(.N(N)) u_wfifo (
        .clk(clk), .reset(reset),
        .fill_ready(fill_ready), .fill_slot_next(fill_slot_next), .fill_advance(fill_advance),
        .fill_we(fill_we), .fill_slot(fill_slot), .fill_row(fill_row), .fill_data(fill_data),
        .tile(tile), .tile_full(tile_full), .take(tile_take));

    // -- UB rows -> systolic data setup -> mmu -> accumulators ----------------------
    logic                     act_valid, act_first;
    logic                     wvalid;
    logic [RW-1:0]            wrow;
    logic signed [N-1:0][7:0] wdata;
    logic                     tag_push, row_written;
    logic [ACC_AW:0]          tag_in;

    // the flip bit rides through the skew beside each activation byte
    logic signed [N-1:0][8:0] sds_in, skewed;
    logic        [N-1:0]      skewed_valid;
    always_comb
        for (int r = 0; r < N; r++)
            sds_in[r] = {act_first, ub_rdata[8*r +: 8]};

    systolic_data_setup #(.ARRAY_ROWS(N), .DATA_WIDTH(9)) u_sds (
        .clk(clk), .reset(reset),
        .ub_read_data(sds_in), .ub_read_valid(act_valid),
        .mmu_in_row(skewed), .mmu_in_valid(skewed_valid));

    logic signed [N-1:0][7:0]  arr_act;
    logic        [N-1:0]       arr_first;
    logic signed [N-1:0][31:0] psum;
    logic        [N-1:0]       psum_valid;
    always_comb
        for (int r = 0; r < N; r++) begin
            arr_act[r]   = skewed[r][7:0];
            arr_first[r] = skewed[r][8];
        end

    mmu #(.N(N)) u_mmu (
        .clk(clk), .reset(reset),
        .act(arr_act), .act_first(arr_first), .act_valid(skewed_valid),
        .wvalid(wvalid), .wrow(wrow), .wdata(wdata),
        .psum(psum), .psum_valid(psum_valid));

    logic [ACC_AW-1:0] act_acc_raddr;
    logic              act_acc_busy;
    logic [N*32-1:0]   acc_rdata;

    accumulator #(.N(N), .ACC_DEPTH(ACC_DEPTH)) u_acc (
        .clk(clk), .reset(reset),
        .psum(psum), .psum_valid(psum_valid),
        .tag_push(tag_push), .tag_in(tag_in), .row_written(row_written),
        .act_raddr(act_acc_raddr), .act_busy(act_acc_busy), .rdata(acc_rdata));

    // -- accumulators -> bias -> activation (sequenced by ACT) ----------------------
    logic            use_bias, relu, mul_en;
    logic [N*32-1:0] biased, act_row, mul_in;
    logic [N*8-1:0]  q_row;

    bias #(.N(N)) u_bias (
        .in_row(acc_rdata), .bias_row(bias_rdata), .enable(use_bias), .out_row(biased));

    activation #(.N(N)) u_activation (
        .clk(clk), .reset(reset),
        .in_row(biased), .relu(relu), .out_row(act_row),
        .mul_en(mul_en), .mul_in(mul_in), .quant_row(quant_rdata), .q_row(q_row));

    // -- engines -------------------------------------------------------------------
    logic [3:0] eng_idle;
    logic       perf_beat, perf_wstall, perf_sync;

    ld_engine #(.N(N), .WMEM_AW(WMEM_AW), .UB_AW(UB_AW), .PAR_AW(PAR_AW)) u_ld (
        .clk(clk), .reset(reset),
        .q_valid(!q_empty[ENG_LD]), .q_data(q_head[ENG_LD]), .q_pop(q_pop[ENG_LD]),
        .completed(completed), .done_pulse(done_pulse[ENG_LD]),
        .data_valid(!data_empty), .ub_wbusy(act_ub_we), .data(data_head), .data_pop(data_pop),
        .wmem_we(wmem_we), .wmem_waddr(wmem_waddr), .ub_we(ub_we), .ub_waddr(ub_waddr),
        .row_wdata(ld_row), .bias_we(bias_we), .quant_we(quant_we),
        .par_waddr(par_waddr), .par_wdata(par_wdata), .idle(eng_idle[ENG_LD]));

    wt_engine #(.N(N), .WMEM_AW(WMEM_AW)) u_wt (
        .clk(clk), .reset(reset),
        .q_valid(!q_empty[ENG_WT]), .q_data(q_head[ENG_WT]), .q_pop(q_pop[ENG_WT]),
        .completed(completed), .done_pulse(done_pulse[ENG_WT]),
        .wmem_raddr(wmem_raddr), .wmem_rdata(wmem_rdata),
        .fill_ready(fill_ready), .fill_slot_next(fill_slot_next), .fill_advance(fill_advance),
        .fill_we(fill_we), .fill_slot(fill_slot), .fill_row(fill_row), .fill_data(fill_data),
        .idle(eng_idle[ENG_WT]));

    mm_engine #(.N(N), .UB_AW(UB_AW), .ACC_AW(ACC_AW)) u_mm (
        .clk(clk), .reset(reset),
        .q_valid(!q_empty[ENG_MM]), .q_data(q_head[ENG_MM]), .q_pop(q_pop[ENG_MM]),
        .completed(completed), .done_pulse(done_pulse[ENG_MM]),
        .tile(tile), .tile_full(tile_full), .tile_take(tile_take),
        .ub_re(mm_ub_re), .ub_raddr(mm_ub_raddr), .act_valid(act_valid), .act_first(act_first),
        .wvalid(wvalid), .wrow(wrow), .wdata(wdata),
        .tag_push(tag_push), .tag_in(tag_in), .row_written(row_written),
        .perf_beat(perf_beat), .perf_wstall(perf_wstall), .perf_sync(perf_sync),
        .idle(eng_idle[ENG_MM]));

    act_engine #(.N(N), .UB_AW(UB_AW), .ACC_AW(ACC_AW), .PAR_AW(PAR_AW)) u_act (
        .clk(clk), .reset(reset),
        .q_valid(!q_empty[ENG_ACT]), .q_data(q_head[ENG_ACT]), .q_pop(q_pop[ENG_ACT]),
        .completed(completed), .done_pulse(done_pulse[ENG_ACT]),
        .acc_raddr(act_acc_raddr), .acc_busy(act_acc_busy),
        .bias_raddr(par_raddr), .use_bias(use_bias), .relu(relu), .act_row(act_row),
        .mul_en(mul_en), .mul_in(mul_in), .q_row(q_row),
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
