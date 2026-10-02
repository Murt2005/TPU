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

    input  logic        instruction_push,
    input  logic [63:0] instruction_word,
    output logic        instruction_full,
    input  logic        data_push,
    input  logic [31:0] data_word,
    output logic        data_full,
    input  logic        output_pop,
    output logic [31:0] output_word,
    output logic        output_empty,

    input  logic        clear_done,
    input  logic        clear_performance,
    output logic        done,
    output logic        error,
    output logic [7:0]  error_code,
    output logic [31:0] error_sequence,
    output logic [15:0] tag,
    output logic        idle,
    output logic [9:0]  instruction_free,
    output logic [10:0] data_free,
    output logic [10:0] output_count,
    output logic [31:0] performance_cycles,
    output logic [31:0] performance_matmul_beats,
    output logic [31:0] performance_matmul_weight_stalls,
    output logic [31:0] performance_matmul_sync_stalls
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
        .clk(clk), .reset(reset), .write_enable_in(instruction_push), .write_data_in(instruction_word),
        .read_enable_in(instruction_pop), .read_data_out(instruction_head), .full_out(instruction_full), .empty_out(instruction_empty));
    fifo #(.WIDTH(32), .DEPTH(DATA_FIFO_DEPTH)) u_data_fifo (
        .clk(clk), .reset(reset), .write_enable_in(data_push), .write_data_in(data_word),
        .read_enable_in(data_pop), .read_data_out(data_head), .full_out(data_full), .empty_out(data_empty));
    fifo #(.WIDTH(32), .DEPTH(OUTPUT_FIFO_DEPTH)) u_output_fifo (
        .clk(clk), .reset(reset), .write_enable_in(output_push), .write_data_in(output_in),
        .read_enable_in(output_pop), .read_data_out(output_word), .full_out(output_full), .empty_out(output_empty));

    logic [10:0] instruction_occupancy, data_occupancy, output_occupancy;
    always_ff @(posedge clk) begin
        if (reset) begin
            instruction_occupancy <= '0; data_occupancy <= '0; output_occupancy <= '0;
        end else begin
            instruction_occupancy <= instruction_occupancy + 11'(instruction_push && !instruction_full) - 11'(instruction_pop && !instruction_empty);
            data_occupancy        <= data_occupancy + 11'(data_push && !data_full) - 11'(data_pop && !data_empty);
            output_occupancy      <= output_occupancy + 11'(output_push && !output_full) - 11'(output_pop && !output_empty);
        end
    end
    assign instruction_free = 10'(11'(INSTRUCTION_FIFO_DEPTH) - instruction_occupancy);
    assign data_free        = 11'(DATA_FIFO_DEPTH) - data_occupancy;
    assign output_count     = output_occupancy;

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
        .instruction_valid(!instruction_empty), .instruction(instruction_head), .instruction_pop(instruction_pop),
        .queue_push(queue_push), .queue_entry(queue_in), .queue_full(queue_full),
        .completed(completed), .dispatched(dispatched),
        .error(error), .error_code(error_code), .error_sequence(error_sequence),
        .done(done), .tag(tag), .clear_done(clear_done), .fence_pending(fence_pending));

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
            array_activation[row]   = skewed[row][7:0];
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
        .queue_valid(!queue_empty[ENGINE_LOAD]), .queue_entry(queue_head[ENGINE_LOAD]), .queue_pop(queue_pop[ENGINE_LOAD]),
        .completed(completed), .instruction_done(instruction_done[ENGINE_LOAD]),
        .data_valid(!data_empty), .UB_write_blocked(activate_UB_write_enable), .data(data_head), .data_pop(data_pop),
        .WMEM_write_enable(WMEM_write_enable), .WMEM_write_address(WMEM_write_address), .UB_write_enable(load_UB_write_enable), .UB_write_address(load_UB_write_address),
        .row_write_data(load_row_data), .bias_write_enable(bias_write_enable), .quantization_write_enable(quantization_write_enable),
        .parameter_write_address(parameter_write_address), .parameter_write_data(parameter_write_data), .idle(engine_idle[ENGINE_LOAD]));

    weight_engine #(.ARRAY_SIZE(ARRAY_SIZE), .WMEM_ADDRESS_WIDTH(WMEM_ADDRESS_WIDTH)) u_weight_engine (
        .clk(clk), .reset(reset),
        .queue_valid(!queue_empty[ENGINE_WEIGHT]), .queue_entry(queue_head[ENGINE_WEIGHT]), .queue_pop(queue_pop[ENGINE_WEIGHT]),
        .completed(completed), .instruction_done(instruction_done[ENGINE_WEIGHT]),
        .WMEM_read_address(WMEM_read_address), .WMEM_read_data(WMEM_read_data),
        .fill_ready(fill_ready), .fill_slot_next(fill_slot_next), .fill_advance(fill_advance),
        .fill_write_enable(fill_write_enable), .fill_slot(fill_slot), .fill_row(fill_row), .fill_data(fill_data),
        .idle(engine_idle[ENGINE_WEIGHT]));

    matmul_engine #(.ARRAY_SIZE(ARRAY_SIZE), .UB_ADDRESS_WIDTH(UB_ADDRESS_WIDTH), .ACC_ADDRESS_WIDTH(ACC_ADDRESS_WIDTH)) u_matmul_engine (
        .clk(clk), .reset(reset),
        .queue_valid(!queue_empty[ENGINE_MATMUL]), .queue_entry(queue_head[ENGINE_MATMUL]), .queue_pop(queue_pop[ENGINE_MATMUL]),
        .completed(completed), .instruction_done(instruction_done[ENGINE_MATMUL]),
        .tile(tile), .tile_full(tile_full), .tile_take(tile_take),
        .UB_read_enable(matmul_UB_read_enable), .UB_read_address(matmul_UB_read_address), .activation_valid(activation_valid), .activation_weight_flip(activation_weight_flip),
        .weight_valid(weight_valid), .weight_row(weight_row), .weight_data(weight_data),
        .tag_push(tag_push), .tag_in(tag_in), .row_written(row_written),
        .performance_beat(performance_beat), .performance_weight_stall(performance_weight_stall), .performance_sync_stall(performance_sync_stall),
        .idle(engine_idle[ENGINE_MATMUL]));

    activate_engine #(.ARRAY_SIZE(ARRAY_SIZE), .UB_ADDRESS_WIDTH(UB_ADDRESS_WIDTH), .ACC_ADDRESS_WIDTH(ACC_ADDRESS_WIDTH), .PARAMETER_ADDRESS_WIDTH(PARAMETER_ADDRESS_WIDTH)) u_activate_engine (
        .clk(clk), .reset(reset),
        .queue_valid(!queue_empty[ENGINE_ACTIVATE]), .queue_entry(queue_head[ENGINE_ACTIVATE]), .queue_pop(queue_pop[ENGINE_ACTIVATE]),
        .completed(completed), .instruction_done(instruction_done[ENGINE_ACTIVATE]),
        .ACC_read_address(activate_ACC_read_address), .ACC_read_blocked(activate_ACC_read_blocked),
        .parameter_read_address(parameter_read_address), .use_bias(use_bias), .relu(relu), .activation_row(activation_row),
        .multiply_enable(multiply_enable), .multiply_in(multiply_in), .quantized_row(quantized_row),
        .UB_write_enable(activate_UB_write_enable), .UB_write_address(activate_UB_write_address), .UB_write_data(activate_UB_write_data),
        .UB_read_enable(activate_UB_read_enable), .UB_read_address(activate_UB_read_address), .UB_read_blocked(matmul_UB_read_enable), .UB_read_data(UB_read_data),
        .output_push(output_push), .output_word(output_in), .output_full(output_full), .idle(engine_idle[ENGINE_ACTIVATE]));

    assign idle = instruction_empty && engine_idle == 4'hF && !fence_pending;

    // -- performance counters --------------------------------------------------
    always_ff @(posedge clk) begin
        if (reset || clear_performance) begin
            performance_cycles <= '0; performance_matmul_beats <= '0; performance_matmul_weight_stalls <= '0; performance_matmul_sync_stalls <= '0;
        end else begin
            performance_cycles               <= performance_cycles + 32'd1;
            performance_matmul_beats         <= performance_matmul_beats + 32'(performance_beat);
            performance_matmul_weight_stalls <= performance_matmul_weight_stalls + 32'(performance_weight_stall);
            performance_matmul_sync_stalls   <= performance_matmul_sync_stalls + 32'(performance_sync_stall);
        end
    end

endmodule
