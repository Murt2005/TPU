`timescale 1ns / 1ps

// DE1-SoC top: host_bridge + tpu_core + power-on reset
module tpu_top #(
    parameter int ARRAY_SIZE      = 8,
    parameter int WMEM_ROWS       = 8192,
    parameter int UB_DEPTH        = 16384,
    parameter int ACC_DEPTH       = 1024,
    parameter int PARAMETER_DEPTH = 256
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

    logic        instruction_push, instruction_full, data_push, data_full, output_pop, output_empty;
    logic [63:0] instruction_word;
    logic [31:0] data_word, output_word;
    logic        clear_done, clear_performance, done, error, idle;
    logic [7:0]  error_code;
    logic [31:0] error_sequence, performance_cycles, performance_matmul_beats, performance_matmul_weight_stalls, performance_matmul_sync_stalls;
    logic [15:0] tag;
    logic [9:0]  instruction_free;
    logic [10:0] data_free, output_count;

    host_bridge u_bridge (
        .clk(clk), .reset(rst),
        .avs_address(avs_address), .avs_read(avs_read), .avs_readdata(avs_readdata),
        .avs_write(avs_write), .avs_writedata(avs_writedata), .avs_waitrequest(avs_waitrequest),
        .instruction_push(instruction_push), .instruction_word(instruction_word), .instruction_full(instruction_full),
        .data_push(data_push), .data_word(data_word), .data_full(data_full),
        .output_pop(output_pop), .output_word(output_word), .output_empty(output_empty),
        .core_reset(core_reset), .clear_done(clear_done), .clear_performance(clear_performance),
        .done(done), .error(error), .error_code(error_code), .error_sequence(error_sequence), .tag(tag), .idle(idle),
        .instruction_free(instruction_free), .data_free(data_free), .output_count(output_count),
        .performance_cycles(performance_cycles), .performance_matmul_beats(performance_matmul_beats),
        .performance_matmul_weight_stalls(performance_matmul_weight_stalls), .performance_matmul_sync_stalls(performance_matmul_sync_stalls));

    tpu_core #(.ARRAY_SIZE(ARRAY_SIZE), .WMEM_ROWS(WMEM_ROWS), .UB_DEPTH(UB_DEPTH), .ACC_DEPTH(ACC_DEPTH),
               .PARAMETER_DEPTH(PARAMETER_DEPTH)) u_core (
        .clk(clk), .reset(rst | core_reset),
        .instruction_push(instruction_push), .instruction_word(instruction_word), .instruction_full(instruction_full),
        .data_push(data_push), .data_word(data_word), .data_full(data_full),
        .output_pop(output_pop), .output_word(output_word), .output_empty(output_empty),
        .clear_done(clear_done), .clear_performance(clear_performance),
        .done(done), .error(error), .error_code(error_code), .error_sequence(error_sequence), .tag(tag), .idle(idle),
        .instruction_free(instruction_free), .data_free(data_free), .output_count(output_count),
        .performance_cycles(performance_cycles), .performance_matmul_beats(performance_matmul_beats),
        .performance_matmul_weight_stalls(performance_matmul_weight_stalls), .performance_matmul_sync_stalls(performance_matmul_sync_stalls));

endmodule
