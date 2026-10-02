`timescale 1ns / 1ps

import tpu_pkg::*;

// the TPU core: host FIFOs, the dispatcher and four engines (control), around the
// TPUv1 datapath: unified buffer -> systolic data setup -> mmu -> accumulators ->
// bias -> activation, with weights from WMEM through the weight FIFO.
// board-neutral; a bridge in front of it speaks the host bus
module tpu_core #(
    parameter int ARRAY_SIZE             = 8,
    parameter int WMEM_ROWS              = 8192,
    parameter int UB_DEPTH               = 16384,
    parameter int ACC_DEPTH              = 1024,
    parameter int PARAMETER_DEPTH        = 256,
    parameter int INSTRUCTION_FIFO_DEPTH = 512,
    parameter int DATA_FIFO_DEPTH        = 1024,
    parameter int OUTPUT_FIFO_DEPTH      = 1024,
    parameter int QUEUE_DEPTH            = 8
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        instruction_push_in,
    input  logic [63:0] instruction_word_in,
    output logic        instruction_full_out,
    input  logic        data_push_in,
    input  logic [31:0] data_word_in,
    output logic        data_full_out,
    input  logic        output_pop_in,
    output logic [31:0] output_word_out,
    output logic        output_empty_out,

    input  logic        clear_done_in,
    input  logic        clear_performance_in,
    output logic        done_out,
    output logic        error_out,
    output logic [7:0]  error_code_out,
    output logic [31:0] error_sequence_out,
    output logic [15:0] tag_out,
    output logic        idle_out,
    output logic [9:0]  instruction_free_out,
    output logic [10:0] data_free_out,
    output logic [10:0] output_count_out,
    output logic [31:0] performance_cycles_out,
    output logic [31:0] performance_matmul_beats_out,
    output logic [31:0] performance_matmul_weight_stalls_out,
    output logic [31:0] performance_matmul_sync_stalls_out
);

    initial begin
        if (ARRAY_SIZE % 4 != 0) $fatal(1, "tpu_core: ARRAY_SIZE=%0d must be a multiple of 4", ARRAY_SIZE);
    end

    localparam int WMEM_ADDRESS_WIDTH      = $clog2(WMEM_ROWS);
    localparam int UB_ADDRESS_WIDTH        = $clog2(UB_DEPTH);
    localparam int ACC_ADDRESS_WIDTH       = $clog2(ACC_DEPTH);
    localparam int PARAMETER_ADDRESS_WIDTH = $clog2(PARAMETER_DEPTH);
    localparam int ROW_SELECT_WIDTH        = $clog2(ARRAY_SIZE);

    // -- host FIFOs, with occupancy counts for LEVELS ------------------------
    logic        instruction_empty;
    logic [63:0] instruction_head;
    logic        instruction_pop;
    logic        data_empty, data_pop;
    logic [31:0] data_head;
    logic        output_push, output_full;
    logic [31:0] output_in;

    fifo #(.WIDTH(64), .DEPTH(INSTRUCTION_FIFO_DEPTH)) u_instruction_fifo (
        .clk(clk), .reset(reset), .write_enable_in(instruction_push_in), .write_data_in(instruction_word_in),
        .read_enable_in(instruction_pop), .read_data_out(instruction_head), .full_out(instruction_full_out), .empty_out(instruction_empty));
    fifo #(.WIDTH(32), .DEPTH(DATA_FIFO_DEPTH)) u_data_fifo (
        .clk(clk), .reset(reset), .write_enable_in(data_push_in), .write_data_in(data_word_in),
        .read_enable_in(data_pop), .read_data_out(data_head), .full_out(data_full_out), .empty_out(data_empty));
    fifo #(.WIDTH(32), .DEPTH(OUTPUT_FIFO_DEPTH)) u_output_fifo (
        .clk(clk), .reset(reset), .write_enable_in(output_push), .write_data_in(output_in),
        .read_enable_in(output_pop_in), .read_data_out(output_word_out), .full_out(output_full), .empty_out(output_empty_out));

    logic [10:0] instruction_occupancy, data_occupancy, output_occupancy;
    always_ff @(posedge clk) begin
        if (reset) begin
            instruction_occupancy <= '0; data_occupancy <= '0; output_occupancy <= '0;
        end else begin
            instruction_occupancy <= instruction_occupancy + 11'(instruction_push_in && !instruction_full_out) - 11'(instruction_pop && !instruction_empty);
            data_occupancy        <= data_occupancy + 11'(data_push_in && !data_full_out) - 11'(data_pop && !data_empty);
            output_occupancy      <= output_occupancy + 11'(output_push && !output_full) - 11'(output_pop_in && !output_empty_out);
        end
    end
    assign instruction_free_out = 10'(11'(INSTRUCTION_FIFO_DEPTH) - instruction_occupancy);
    assign data_free_out        = 11'(DATA_FIFO_DEPTH) - data_occupancy;
    assign output_count_out     = output_occupancy;

    // -- dispatcher + engine queues --------------------------------------------
    logic [3:0]                   queue_push, queue_full, queue_empty, queue_pop;
    logic [QUEUE_ENTRY_WIDTH-1:0] queue_in;
    logic [QUEUE_ENTRY_WIDTH-1:0]     queue_head [4];
    logic [63:0] dispatched, completed;
    logic [3:0]  instruction_done;
    logic        fence_pending;

    dispatch #(.ARRAY_SIZE(ARRAY_SIZE), .WMEM_ROWS(WMEM_ROWS), .UB_DEPTH(UB_DEPTH), .ACC_DEPTH(ACC_DEPTH),
               .PARAMETER_DEPTH(PARAMETER_DEPTH)) u_dispatch (
        .clk(clk), .reset(reset),
        .instruction_valid_in(!instruction_empty), .instruction_in(instruction_head), .instruction_pop_out(instruction_pop),
        .queue_push_out(queue_push), .queue_entry_out(queue_in), .queue_full_in(queue_full),
        .completed_in(completed), .dispatched_out(dispatched),
        .error_out(error_out), .error_code_out(error_code_out), .error_sequence_out(error_sequence_out),
        .done_out(done_out), .tag_out(tag_out), .clear_done_in(clear_done_in), .fence_pending_out(fence_pending));

    genvar engine_queue;
    generate
        for (engine_queue = 0; engine_queue < 4; engine_queue++) begin : g_queue
            fifo #(.WIDTH(QUEUE_ENTRY_WIDTH), .DEPTH(QUEUE_DEPTH)) u_queue (
                .clk(clk), .reset(reset), .write_enable_in(queue_push[engine_queue]), .write_data_in(queue_in),
                .read_enable_in(queue_pop[engine_queue]), .read_data_out(queue_head[engine_queue]),
                .full_out(queue_full[engine_queue]), .empty_out(queue_empty[engine_queue]));
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (reset) completed <= '0;
        else for (int engine = 0; engine < 4; engine++)
            if (instruction_done[engine]) completed[16*engine +: 16] <= completed[16*engine +: 16] + 16'd1;
    end

    // -- WMEM and the parameter tables (registered reads, so they map to block RAM)
    logic [ARRAY_SIZE*8-1:0]  WMEM [WMEM_ROWS];
    logic [ARRAY_SIZE*32-1:0] bias_table  [PARAMETER_DEPTH];
    logic [ARRAY_SIZE*32-1:0] quantization_table [PARAMETER_DEPTH];

    logic                               WMEM_write_enable, load_UB_write_enable, bias_write_enable, quantization_write_enable;
    logic [WMEM_ADDRESS_WIDTH-1:0]      WMEM_write_address, WMEM_read_address;
    logic [UB_ADDRESS_WIDTH-1:0]        load_UB_write_address;
    logic [ARRAY_SIZE*8-1:0]            load_row_data;
    logic [PARAMETER_ADDRESS_WIDTH-1:0] parameter_write_address, parameter_read_address;
    logic [ARRAY_SIZE*32-1:0]           parameter_write_data;
    logic [ARRAY_SIZE*8-1:0]            WMEM_read_data;
    logic [ARRAY_SIZE*32-1:0]           bias_read_data, quantization_read_data;

    always_ff @(posedge clk) begin
        if (WMEM_write_enable)  WMEM[WMEM_write_address]     <= load_row_data;
        if (bias_write_enable)  bias_table[parameter_write_address]  <= parameter_write_data;
        if (quantization_write_enable) quantization_table[parameter_write_address] <= parameter_write_data;
        WMEM_read_data         <= WMEM[WMEM_read_address];
        bias_read_data         <= bias_table[parameter_read_address];
        quantization_read_data <= quantization_table[parameter_read_address];
    end

    // -- unified buffer ----------------------------------------------------------
    logic                        matmul_UB_read_enable, activate_UB_read_enable, activate_UB_write_enable;
    logic [UB_ADDRESS_WIDTH-1:0] matmul_UB_read_address, activate_UB_read_address, activate_UB_write_address;
    logic [ARRAY_SIZE*8-1:0]     activate_UB_write_data, UB_read_data;

    unified_buffer #(.ARRAY_SIZE(ARRAY_SIZE), .DEPTH(UB_DEPTH)) u_unified_buffer (
        .clk(clk),
        .load_write_enable_in(load_UB_write_enable), .load_write_address_in(load_UB_write_address), .load_write_data_in(load_row_data),
        .activate_write_enable_in(activate_UB_write_enable), .activate_write_address_in(activate_UB_write_address), .activate_write_data_in(activate_UB_write_data),
        .matmul_read_enable_in(matmul_UB_read_enable), .matmul_read_address_in(matmul_UB_read_address), .activate_read_address_in(activate_UB_read_address),
        .read_data_out(UB_read_data));

    // -- weight FIFO: WT fills, MM drains ------------------------------------------
    logic                                     fill_ready, fill_slot_next, fill_advance, fill_write_enable, fill_slot;
    logic [7:0]                               fill_row;
    logic [ARRAY_SIZE*8-1:0]                  fill_data;
    logic [ARRAY_SIZE-1:0] [ARRAY_SIZE*8-1:0] tile;
    logic                                     tile_full, tile_take;

    weight_fifo #(.ARRAY_SIZE(ARRAY_SIZE)) u_weight_fifo (
        .clk(clk), .reset(reset),
        .fill_ready_out(fill_ready), .fill_slot_next_out(fill_slot_next), .fill_advance_in(fill_advance),
        .fill_write_enable_in(fill_write_enable), .fill_slot_in(fill_slot), .fill_row_in(fill_row), .fill_data_in(fill_data),
        .tile_out(tile), .tile_full_out(tile_full), .tile_take_in(tile_take));

    // -- UB rows -> systolic data setup -> mmu -> accumulators ----------------------
    logic                               activation_valid, activation_weight_flip;
    logic                               weight_valid;
    logic        [ROW_SELECT_WIDTH-1:0] weight_row;
    logic signed [ARRAY_SIZE-1:0] [7:0] weight_data;
    logic                               tag_push, row_written;
    logic        [ACC_ADDRESS_WIDTH:0]  tag_in;

    // the flip bit rides through the skew beside each activation byte
    logic signed [ARRAY_SIZE-1:0] [8:0] skew_in, skewed;
    logic        [ARRAY_SIZE-1:0]       skewed_valid;
    always_comb
        for (int row = 0; row < ARRAY_SIZE; row++)
            skew_in[row] = {activation_weight_flip, UB_read_data[8*row +: 8]};

    systolic_data_setup #(.ARRAY_SIZE(ARRAY_SIZE), .DATA_WIDTH(9)) u_systolic_data_setup (
        .clk(clk), .reset(reset),
        .row_in(skew_in), .row_valid_in(activation_valid),
        .skewed_row_out(skewed), .skewed_valid_out(skewed_valid));

    logic signed [ARRAY_SIZE-1:0] [7:0]  array_activation;
    logic        [ARRAY_SIZE-1:0]        array_weight_flip;
    logic signed [ARRAY_SIZE-1:0] [31:0] partial_sum;
    logic        [ARRAY_SIZE-1:0]        partial_sum_valid;
    always_comb
        for (int row = 0; row < ARRAY_SIZE; row++) begin
            array_activation[row]  = skewed[row][7:0];
            array_weight_flip[row] = skewed[row][8];
        end

    mmu #(.ARRAY_SIZE(ARRAY_SIZE)) u_mmu (
        .clk(clk), .reset(reset),
        .activation_in(array_activation), .weight_flip_in(array_weight_flip), .activation_valid_in(skewed_valid),
        .weight_valid_in(weight_valid), .weight_row_select_in(weight_row), .weight_in(weight_data),
        .partial_sum_out(partial_sum), .partial_sum_valid_out(partial_sum_valid));

    logic [ACC_ADDRESS_WIDTH-1:0] activate_ACC_read_address;
    logic                         activate_ACC_read_blocked;
    logic [ARRAY_SIZE*32-1:0]     ACC_read_data;

    accumulator #(.ARRAY_SIZE(ARRAY_SIZE), .ACC_DEPTH(ACC_DEPTH)) u_accumulator (
        .clk(clk), .reset(reset),
        .partial_sum_in(partial_sum), .partial_sum_valid_in(partial_sum_valid),
        .tag_push_in(tag_push), .tag_in(tag_in), .row_written_out(row_written),
        .activate_read_address_in(activate_ACC_read_address), .activate_read_blocked_out(activate_ACC_read_blocked), .read_data_out(ACC_read_data));

    // -- accumulators -> bias -> activation (sequenced by ACT) ----------------------
    logic                     use_bias, relu, multiply_enable;
    logic [ARRAY_SIZE*32-1:0] biased, activation_row, multiply_in;
    logic [ARRAY_SIZE*8-1:0]  quantized_row;

    bias #(.ARRAY_SIZE(ARRAY_SIZE)) u_bias (
        .row_in(ACC_read_data), .bias_row_in(bias_read_data), .bias_enable_in(use_bias), .row_out(biased));

    activation #(.ARRAY_SIZE(ARRAY_SIZE)) u_activation (
        .clk(clk), .reset(reset),
        .row_in(biased), .relu_enable_in(relu), .row_out(activation_row),
        .multiply_enable_in(multiply_enable), .multiply_row_in(multiply_in), .quantization_row_in(quantization_read_data), .quantized_row_out(quantized_row));

    // -- engines -------------------------------------------------------------------
    logic [3:0] engine_idle;
    logic       performance_beat, performance_weight_stall, performance_sync_stall;

    load_engine #(.ARRAY_SIZE(ARRAY_SIZE), .WMEM_ADDRESS_WIDTH(WMEM_ADDRESS_WIDTH), .UB_ADDRESS_WIDTH(UB_ADDRESS_WIDTH), .PARAMETER_ADDRESS_WIDTH(PARAMETER_ADDRESS_WIDTH)) u_load_engine (
        .clk(clk), .reset(reset),
        .queue_valid_in(!queue_empty[ENGINE_LOAD]), .queue_entry_in(queue_head[ENGINE_LOAD]), .queue_pop_out(queue_pop[ENGINE_LOAD]),
        .completed_in(completed), .instruction_done_out(instruction_done[ENGINE_LOAD]),
        .data_valid_in(!data_empty), .UB_write_blocked_in(activate_UB_write_enable), .data_in(data_head), .data_pop_out(data_pop),
        .WMEM_write_enable_out(WMEM_write_enable), .WMEM_write_address_out(WMEM_write_address), .UB_write_enable_out(load_UB_write_enable), .UB_write_address_out(load_UB_write_address),
        .row_write_data_out(load_row_data), .bias_write_enable_out(bias_write_enable), .quantization_write_enable_out(quantization_write_enable),
        .parameter_write_address_out(parameter_write_address), .parameter_write_data_out(parameter_write_data), .idle_out(engine_idle[ENGINE_LOAD]));

    weight_engine #(.ARRAY_SIZE(ARRAY_SIZE), .WMEM_ADDRESS_WIDTH(WMEM_ADDRESS_WIDTH)) u_weight_engine (
        .clk(clk), .reset(reset),
        .queue_valid_in(!queue_empty[ENGINE_WEIGHT]), .queue_entry_in(queue_head[ENGINE_WEIGHT]), .queue_pop_out(queue_pop[ENGINE_WEIGHT]),
        .completed_in(completed), .instruction_done_out(instruction_done[ENGINE_WEIGHT]),
        .WMEM_read_address_out(WMEM_read_address), .WMEM_read_data_in(WMEM_read_data),
        .fill_ready_in(fill_ready), .fill_slot_next_in(fill_slot_next), .fill_advance_out(fill_advance),
        .fill_write_enable_out(fill_write_enable), .fill_slot_out(fill_slot), .fill_row_out(fill_row), .fill_data_out(fill_data),
        .idle_out(engine_idle[ENGINE_WEIGHT]));

    matmul_engine #(.ARRAY_SIZE(ARRAY_SIZE), .UB_ADDRESS_WIDTH(UB_ADDRESS_WIDTH), .ACC_ADDRESS_WIDTH(ACC_ADDRESS_WIDTH)) u_matmul_engine (
        .clk(clk), .reset(reset),
        .queue_valid_in(!queue_empty[ENGINE_MATMUL]), .queue_entry_in(queue_head[ENGINE_MATMUL]), .queue_pop_out(queue_pop[ENGINE_MATMUL]),
        .completed_in(completed), .instruction_done_out(instruction_done[ENGINE_MATMUL]),
        .tile_in(tile), .tile_full_in(tile_full), .tile_take_out(tile_take),
        .UB_read_enable_out(matmul_UB_read_enable), .UB_read_address_out(matmul_UB_read_address), .activation_valid_out(activation_valid), .activation_weight_flip_out(activation_weight_flip),
        .weight_valid_out(weight_valid), .weight_row_select_out(weight_row), .weight_data_out(weight_data),
        .tag_push_out(tag_push), .tag_out(tag_in), .row_written_in(row_written),
        .performance_beat_out(performance_beat), .performance_weight_stall_out(performance_weight_stall), .performance_sync_stall_out(performance_sync_stall),
        .idle_out(engine_idle[ENGINE_MATMUL]));

    activate_engine #(.ARRAY_SIZE(ARRAY_SIZE), .UB_ADDRESS_WIDTH(UB_ADDRESS_WIDTH), .ACC_ADDRESS_WIDTH(ACC_ADDRESS_WIDTH), .PARAMETER_ADDRESS_WIDTH(PARAMETER_ADDRESS_WIDTH)) u_activate_engine (
        .clk(clk), .reset(reset),
        .queue_valid_in(!queue_empty[ENGINE_ACTIVATE]), .queue_entry_in(queue_head[ENGINE_ACTIVATE]), .queue_pop_out(queue_pop[ENGINE_ACTIVATE]),
        .completed_in(completed), .instruction_done_out(instruction_done[ENGINE_ACTIVATE]),
        .ACC_read_address_out(activate_ACC_read_address), .ACC_read_blocked_in(activate_ACC_read_blocked),
        .parameter_read_address_out(parameter_read_address), .bias_enable_out(use_bias), .relu_enable_out(relu), .activation_row_in(activation_row),
        .multiply_enable_out(multiply_enable), .multiply_row_out(multiply_in), .quantized_row_in(quantized_row),
        .UB_write_enable_out(activate_UB_write_enable), .UB_write_address_out(activate_UB_write_address), .UB_write_data_out(activate_UB_write_data),
        .UB_read_enable_out(activate_UB_read_enable), .UB_read_address_out(activate_UB_read_address), .UB_read_blocked_in(matmul_UB_read_enable), .UB_read_data_in(UB_read_data),
        .output_push_out(output_push), .output_word_out(output_in), .output_full_in(output_full), .idle_out(engine_idle[ENGINE_ACTIVATE]));

    assign idle_out = instruction_empty && engine_idle == 4'hF && !fence_pending;

    // -- performance counters --------------------------------------------------
    always_ff @(posedge clk) begin
        if (reset || clear_performance_in) begin
            performance_cycles_out <= '0; performance_matmul_beats_out <= '0; performance_matmul_weight_stalls_out <= '0; performance_matmul_sync_stalls_out <= '0;
        end else begin
            performance_cycles_out               <= performance_cycles_out + 32'd1;
            performance_matmul_beats_out         <= performance_matmul_beats_out + 32'(performance_beat);
            performance_matmul_weight_stalls_out <= performance_matmul_weight_stalls_out + 32'(performance_weight_stall);
            performance_matmul_sync_stalls_out   <= performance_matmul_sync_stalls_out + 32'(performance_sync_stall);
        end
    end

endmodule
