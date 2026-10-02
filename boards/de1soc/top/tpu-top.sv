`timescale 1ns / 1ps

// DE1-SoC top: host_bridge + tpu_core + power-on reset; the core's DDR3 master is
// exported for the HPS's FPGA-to-SDRAM port
module tpu_top #(
    parameter int ARRAY_SIZE      = 8,
    parameter int WMEM_ROWS       = 8192,
    parameter int UB_DEPTH        = 16384,
    parameter int ACC_DEPTH       = 1024,
    parameter int PARAMETER_DEPTH = 256,
    parameter longint DDR_BYTES   = 64'h4000_0000
) (
    input  logic        clk,
    input  logic        reset_n,

    // Qsys slave settings: fixed read latency 1, waitrequest on writes
    input  logic [3:0]  avs_address,
    input  logic        avs_read,
    output logic [31:0] avs_readdata,
    input  logic        avs_write,
    input  logic [31:0] avs_writedata,
    output logic        avs_waitrequest,

    // DDR3 burst-read master: byte addresses, 128-bit beats
    output logic [31:0]  avm_address,
    output logic         avm_read,
    output logic [7:0]   avm_burstcount,
    input  logic         avm_waitrequest,
    input  logic [127:0] avm_readdata,
    input  logic         avm_readdatavalid
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
        .instruction_push_out(instruction_push), .instruction_word_out(instruction_word), .instruction_full_in(instruction_full),
        .data_push_out(data_push), .data_word_out(data_word), .data_full_in(data_full),
        .output_pop_out(output_pop), .output_word_in(output_word), .output_empty_in(output_empty),
        .core_reset_out(core_reset), .clear_done_out(clear_done), .clear_performance_out(clear_performance),
        .done_in(done), .error_in(error), .error_code_in(error_code), .error_sequence_in(error_sequence), .tag_in(tag), .idle_in(idle),
        .instruction_free_in(instruction_free), .data_free_in(data_free), .output_count_in(output_count),
        .performance_cycles_in(performance_cycles), .performance_matmul_beats_in(performance_matmul_beats),
        .performance_matmul_weight_stalls_in(performance_matmul_weight_stalls), .performance_matmul_sync_stalls_in(performance_matmul_sync_stalls));

    tpu_core #(.ARRAY_SIZE(ARRAY_SIZE), .WMEM_ROWS(WMEM_ROWS), .UB_DEPTH(UB_DEPTH), .ACC_DEPTH(ACC_DEPTH),
               .PARAMETER_DEPTH(PARAMETER_DEPTH), .DDR_BYTES(DDR_BYTES)) u_core (
        .clk(clk), .reset(rst | core_reset), .bus_reset(rst),
        .instruction_push_in(instruction_push), .instruction_word_in(instruction_word), .instruction_full_out(instruction_full),
        .data_push_in(data_push), .data_word_in(data_word), .data_full_out(data_full),
        .output_pop_in(output_pop), .output_word_out(output_word), .output_empty_out(output_empty),
        .clear_done_in(clear_done), .clear_performance_in(clear_performance),
        .done_out(done), .error_out(error), .error_code_out(error_code), .error_sequence_out(error_sequence), .tag_out(tag), .idle_out(idle),
        .instruction_free_out(instruction_free), .data_free_out(data_free), .output_count_out(output_count),
        .performance_cycles_out(performance_cycles), .performance_matmul_beats_out(performance_matmul_beats),
        .performance_matmul_weight_stalls_out(performance_matmul_weight_stalls), .performance_matmul_sync_stalls_out(performance_matmul_sync_stalls),
        .memory_address_out(avm_address), .memory_read_out(avm_read), .memory_burstcount_out(avm_burstcount),
        .memory_waitrequest_in(avm_waitrequest), .memory_readdata_in(avm_readdata), .memory_readdatavalid_in(avm_readdatavalid));

endmodule
