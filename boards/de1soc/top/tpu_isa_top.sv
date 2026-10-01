`timescale 1ns / 1ps

// DE1-SoC instruction-stream top: isa_bridge + isa_core + power-on reset
module tpu_isa_top #(
    parameter int N           = 8,
    parameter int WMEM_ROWS   = 8192,
    parameter int UB_DEPTH    = 16384,
    parameter int ACC_DEPTH   = 1024,
    parameter int PARAM_DEPTH = 256
) (
    input  logic        clk,
    input  logic        reset_n,

    // Qsys slave settings: fixed read latency 1, waitrequest on writes
    input  logic [3:0]  avs_address,
    input  logic        avs_read,
    output logic [31:0] avs_readdata,
    input  logic        avs_write,
    input  logic [31:0] avs_writedata,
    output logic        avs_waitrequest
);

    // power-on reset, same reason as tpu_top: don't rely on reset_n pulsing
    logic [7:0] por_ctr = '0;
    logic       por_done = 1'b0;
    always_ff @(posedge clk) begin
        if (!por_done) begin
            por_ctr <= por_ctr + 1'b1;
            if (por_ctr == 8'hFF) por_done <= 1'b1;
        end
    end

    logic rst, core_reset;
    assign rst = ~reset_n | ~por_done;

    logic        insn_push, insn_full, data_push, data_full, out_pop, out_empty;
    logic [63:0] insn_word;
    logic [31:0] data_word, out_word;
    logic        clear_done, clear_perf, done, err, idle;
    logic [7:0]  err_code;
    logic [31:0] err_seq, perf_cycles, perf_mm_beats, perf_mm_wstall, perf_mm_sync;
    logic [15:0] tag;
    logic [9:0]  insn_free;
    logic [10:0] data_free, out_count;

    isa_bridge u_bridge (
        .clk(clk), .reset(rst),
        .avs_address(avs_address), .avs_read(avs_read), .avs_readdata(avs_readdata),
        .avs_write(avs_write), .avs_writedata(avs_writedata), .avs_waitrequest(avs_waitrequest),
        .insn_push(insn_push), .insn_word(insn_word), .insn_full(insn_full),
        .data_push(data_push), .data_word(data_word), .data_full(data_full),
        .out_pop(out_pop), .out_word(out_word), .out_empty(out_empty),
        .core_reset(core_reset), .clear_done(clear_done), .clear_perf(clear_perf),
        .done(done), .err(err), .err_code(err_code), .err_seq(err_seq), .tag(tag), .idle(idle),
        .insn_free(insn_free), .data_free(data_free), .out_count(out_count),
        .perf_cycles(perf_cycles), .perf_mm_beats(perf_mm_beats),
        .perf_mm_wstall(perf_mm_wstall), .perf_mm_sync(perf_mm_sync));

    isa_core #(.N(N), .WMEM_ROWS(WMEM_ROWS), .UB_DEPTH(UB_DEPTH), .ACC_DEPTH(ACC_DEPTH),
               .PARAM_DEPTH(PARAM_DEPTH)) u_core (
        .clk(clk), .reset(rst | core_reset),
        .insn_push(insn_push), .insn_word(insn_word), .insn_full(insn_full),
        .data_push(data_push), .data_word(data_word), .data_full(data_full),
        .out_pop(out_pop), .out_word(out_word), .out_empty(out_empty),
        .clear_done(clear_done), .clear_perf(clear_perf),
        .done(done), .err(err), .err_code(err_code), .err_seq(err_seq), .tag(tag), .idle(idle),
        .insn_free(insn_free), .data_free(data_free), .out_count(out_count),
        .perf_cycles(perf_cycles), .perf_mm_beats(perf_mm_beats),
        .perf_mm_wstall(perf_mm_wstall), .perf_mm_sync(perf_mm_sync));

endmodule
