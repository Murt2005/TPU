`timescale 1ns / 1ps

import tpu_pkg::*;

// the TPU core: host FIFOs, the dispatcher and four engines (control), around the
// TPUv1 datapath: unified buffer -> systolic data setup -> mmu -> accumulators ->
// bias -> activation, with weights from WMEM or DDR3 through the weight FIFO.
// board-neutral; a bridge in front of it speaks the host bus, and its DDR3 port is
// an Avalon-MM master: burst reads for WT (MATMUL wsrc=1) and LD (RD_DDR_UB),
// single-beat writes for ACT (ACTIVATE dst=DDR)
module tpu_core #(
    parameter int ARRAY_SIZE             = 8,
    parameter int WMEM_ROWS              = 8192,
    parameter int UB_DEPTH               = 16384,
    parameter int ACC_DEPTH              = 1024,
    parameter int PARAMETER_DEPTH        = 256,
    parameter int INSTRUCTION_FIFO_DEPTH = 512,
    parameter int DATA_FIFO_DEPTH        = 1024,
    parameter int OUTPUT_FIFO_DEPTH      = 1024,
    parameter int QUEUE_DEPTH            = 8,
    parameter int WEIGHT_LANES           = 2,
    parameter int DDR_BEAT_BITS          = 128,            // the DDR3 port: 128 or 256 bits a beat              // weight rows into the array per cycle: tiles every max(m, N / this) cycles
    parameter longint DDR_BYTES          = 64'h4000_0000
) (
    input  logic        clk,
    input  logic        reset,              // power-on or CTRL.RESET
    input  logic        bus_reset,          // power-on only: reads in flight on the DDR3 bus outlive CTRL.RESET

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
    output logic [31:0] performance_matmul_sync_stalls_out,
    input  logic        clear_profile_in,                   // the profiler (rtl/common/profiler.sv)
    input  logic        profile_read_in,
    output logic [31:0] profile_word_out,
    output logic [15:0] profile_level_out,
    output logic [15:0] profile_dropped_out,

    // DDR3: DDR_BEAT_BITS beats, byte addresses
    output logic [31:0]  memory_address_out,
    output logic         memory_read_out,
    output logic         memory_write_out,
    output logic [7:0]   memory_burstcount_out,
    output logic [DDR_BEAT_BITS-1:0]   memory_writedata_out,
    output logic [DDR_BEAT_BITS/8-1:0] memory_byteenable_out,
    input  logic         memory_waitrequest_in,
    input  logic [DDR_BEAT_BITS-1:0] memory_readdata_in,
    input  logic         memory_readdatavalid_in
);

    initial begin
        if (ARRAY_SIZE % 4 != 0) $fatal(1, "tpu_core: ARRAY_SIZE=%0d must be a multiple of 4", ARRAY_SIZE);
    end

    localparam int WMEM_ADDRESS_WIDTH      = $clog2(WMEM_ROWS);
    localparam int UB_ADDRESS_WIDTH        = $clog2(UB_DEPTH);
    localparam int ACC_ADDRESS_WIDTH       = $clog2(ACC_DEPTH);
    localparam int PARAMETER_ADDRESS_WIDTH = $clog2(PARAMETER_DEPTH);
    localparam int ROW_SELECT_WIDTH        = $clog2(ARRAY_SIZE);
    localparam int WEIGHT_SLOTS            = WEIGHT_LANES + 1;
    localparam int SLOT_WIDTH              = WEIGHT_SLOTS > 2 ? $clog2(WEIGHT_SLOTS) : 1;
    localparam int WMEM_GROUP_WIDTH        = $clog2(WMEM_ROWS / WEIGHT_LANES);   // WMEM holds WEIGHT_LANES rows a word

    // -- host FIFOs, with occupancy counts for LEVELS ------------------------
    logic        instruction_empty;
    logic [63:0] instruction_head;
    logic        instruction_pop;
    logic        data_empty, data_pop;
    logic [31:0] data_head;
    logic        output_push, output_full;
    logic [31:0] activate_output_word;

    fifo #(.WIDTH(64), .DEPTH(INSTRUCTION_FIFO_DEPTH)) u_instruction_fifo (
        .clk(clk), .reset(reset), .write_enable_in(instruction_push_in), .write_data_in(instruction_word_in),
        .read_enable_in(instruction_pop), .read_data_out(instruction_head), .full_out(instruction_full_out), .empty_out(instruction_empty));
    fifo #(.WIDTH(32), .DEPTH(DATA_FIFO_DEPTH)) u_data_fifo (
        .clk(clk), .reset(reset), .write_enable_in(data_push_in), .write_data_in(data_word_in),
        .read_enable_in(data_pop), .read_data_out(data_head), .full_out(data_full_out), .empty_out(data_empty));
    fifo #(.WIDTH(32), .DEPTH(OUTPUT_FIFO_DEPTH)) u_output_fifo (
        .clk(clk), .reset(reset), .write_enable_in(output_push), .write_data_in(activate_output_word),
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
    logic [QUEUE_ENTRY_WIDTH-1:0] queue_entry;
    logic [QUEUE_ENTRY_WIDTH-1:0]     queue_head [4];
    logic [63:0] dispatched, completed;
    logic [3:0]  instruction_done;
    logic        fence_pending;

    dispatch #(.ARRAY_SIZE(ARRAY_SIZE), .WMEM_ROWS(WMEM_ROWS), .UB_DEPTH(UB_DEPTH), .ACC_DEPTH(ACC_DEPTH),
               .PARAMETER_DEPTH(PARAMETER_DEPTH), .DDR_BYTES(DDR_BYTES)) u_dispatch (
        .clk(clk), .reset(reset),
        .instruction_valid_in(!instruction_empty), .instruction_in(instruction_head), .instruction_pop_out(instruction_pop),
        .queue_push_out(queue_push), .queue_entry_out(queue_entry), .queue_full_in(queue_full),
        .completed_in(completed), .dispatched_out(dispatched),
        .error_out(error_out), .error_code_out(error_code_out), .error_sequence_out(error_sequence_out),
        .done_out(done_out), .tag_out(tag_out), .clear_done_in(clear_done_in), .fence_pending_out(fence_pending));

    genvar engine_queue;
    generate
        for (engine_queue = 0; engine_queue < 4; engine_queue++) begin : g_queue
            fifo #(.WIDTH(QUEUE_ENTRY_WIDTH), .DEPTH(QUEUE_DEPTH)) u_queue (
                .clk(clk), .reset(reset), .write_enable_in(queue_push[engine_queue]), .write_data_in(queue_entry),
                .read_enable_in(queue_pop[engine_queue]), .read_data_out(queue_head[engine_queue]),
                .full_out(queue_full[engine_queue]), .empty_out(queue_empty[engine_queue]));
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (reset) completed <= '0;
        else for (int engine = 0; engine < 4; engine++)
            if (instruction_done[engine]) completed[16*engine +: 16] <= completed[16*engine +: 16] + 16'd1;
    end

    // -- WMEM and the parameter tables (registered reads, so they map to block RAM).
    // WMEM is WEIGHT_LANES banks, row r in bank r % WEIGHT_LANES, so WT reads a group
    // of rows a cycle; LD writes one row at a time
    logic [ARRAY_SIZE*8-1:0]  WMEM [WEIGHT_LANES][WMEM_ROWS / WEIGHT_LANES];
    logic [ARRAY_SIZE*32-1:0] bias_table  [PARAMETER_DEPTH];
    logic [ARRAY_SIZE*32-1:0] quantization_table [PARAMETER_DEPTH];

    logic                               WMEM_write_enable, load_UB_write_enable, bias_write_enable, quantization_write_enable;
    logic [WMEM_ADDRESS_WIDTH-1:0]      WMEM_write_address;
    logic [WMEM_GROUP_WIDTH-1:0]        WMEM_read_address;
    logic [UB_ADDRESS_WIDTH-1:0]        load_UB_write_address;
    logic [ARRAY_SIZE*8-1:0]            load_row_data;
    logic [PARAMETER_ADDRESS_WIDTH-1:0] parameter_write_address, parameter_read_address;
    logic [ARRAY_SIZE*32-1:0]           parameter_write_data;
    logic [WEIGHT_LANES*ARRAY_SIZE*8-1:0] WMEM_read_data;
    logic [ARRAY_SIZE*32-1:0]           bias_read_data, quantization_read_data;

    always_ff @(posedge clk) begin
        for (int bank = 0; bank < WEIGHT_LANES; bank++) begin
            if (WMEM_write_enable && 32'(WMEM_write_address) % WEIGHT_LANES == bank)
                WMEM[bank][WMEM_GROUP_WIDTH'(32'(WMEM_write_address) / WEIGHT_LANES)] <= load_row_data;
            WMEM_read_data[ARRAY_SIZE*8*bank +: ARRAY_SIZE*8] <= WMEM[bank][WMEM_read_address];
        end
        if (bias_write_enable)  bias_table[parameter_write_address]  <= parameter_write_data;
        if (quantization_write_enable) quantization_table[parameter_write_address] <= parameter_write_data;
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
    logic                                     fill_ready, fill_advance, fill_write_enable;
    logic [SLOT_WIDTH-1:0]                    fill_slot_next, fill_slot, drain_slot;
    logic [7:0]                               fill_row;
    logic [WEIGHT_LANES*ARRAY_SIZE*8-1:0]     fill_data;
    logic [WEIGHT_SLOTS-1:0][ARRAY_SIZE-1:0][ARRAY_SIZE*8-1:0] weight_slots;
    logic [WEIGHT_SLOTS-1:0]                  slot_full;
    logic                                     tile_take;

    weight_fifo #(.ARRAY_SIZE(ARRAY_SIZE), .FILL_ROWS(WEIGHT_LANES), .SLOTS(WEIGHT_SLOTS)) u_weight_fifo (
        .clk(clk), .reset(reset),
        .fill_ready_out(fill_ready), .fill_slot_next_out(fill_slot_next), .fill_advance_in(fill_advance),
        .fill_write_enable_in(fill_write_enable), .fill_slot_in(fill_slot), .fill_row_in(fill_row), .fill_data_in(fill_data),
        .tile_out(), .tile_full_out(), .tile_take_in(tile_take),
        .slots_out(weight_slots), .slot_full_out(slot_full), .drain_slot_out(drain_slot));

    // -- UB rows -> systolic data setup -> mmu -> accumulators ----------------------
    logic                               activation_valid, activation_weight_flip;
    logic        [WEIGHT_LANES-1:0]                       weight_valid;
    logic        [WEIGHT_LANES-1:0][ROW_SELECT_WIDTH-1:0] weight_row_select;
    logic signed [WEIGHT_LANES-1:0][ARRAY_SIZE-1:0][7:0]  weight_data;
    logic                               tag_push, row_written;
    logic        [ACC_ADDRESS_WIDTH:0]  row_tag;

    // the flip bit rides through the skew beside each activation byte
    logic signed [ARRAY_SIZE-1:0] [8:0] unskewed_row, skewed_row;
    logic        [ARRAY_SIZE-1:0]       skewed_valid;
    always_comb
        for (int row = 0; row < ARRAY_SIZE; row++)
            unskewed_row[row] = {activation_weight_flip, UB_read_data[8*row +: 8]};

    systolic_data_setup #(.ARRAY_SIZE(ARRAY_SIZE), .DATA_WIDTH(9)) u_systolic_data_setup (
        .clk(clk), .reset(reset),
        .row_in(unskewed_row), .row_valid_in(activation_valid),
        .skewed_row_out(skewed_row), .skewed_valid_out(skewed_valid));

    logic signed [ARRAY_SIZE-1:0] [7:0]  array_activation;
    logic        [ARRAY_SIZE-1:0]        array_weight_flip;
    logic signed [ARRAY_SIZE-1:0] [31:0] partial_sum;
    logic        [ARRAY_SIZE-1:0]        partial_sum_valid;
    always_comb
        for (int row = 0; row < ARRAY_SIZE; row++) begin
            array_activation[row]  = skewed_row[row][7:0];
            array_weight_flip[row] = skewed_row[row][8];
        end

    mmu #(.ARRAY_SIZE(ARRAY_SIZE), .WEIGHT_LANES(WEIGHT_LANES)) u_mmu (
        .clk(clk), .reset(reset),
        .activation_in(array_activation), .weight_flip_in(array_weight_flip), .activation_valid_in(skewed_valid),
        .weight_valid_in(weight_valid), .weight_row_select_in(weight_row_select), .weight_in(weight_data),
        .partial_sum_out(partial_sum), .partial_sum_valid_out(partial_sum_valid));

    logic [ACC_ADDRESS_WIDTH-1:0] activate_ACC_read_address;
    logic                         activate_ACC_read_blocked;
    logic [ARRAY_SIZE*32-1:0]     ACC_read_data;

    accumulator #(.ARRAY_SIZE(ARRAY_SIZE), .ACC_DEPTH(ACC_DEPTH)) u_accumulator (
        .clk(clk), .reset(reset),
        .partial_sum_in(partial_sum), .partial_sum_valid_in(partial_sum_valid),
        .tag_push_in(tag_push), .tag_in(row_tag), .row_written_out(row_written),
        .activate_read_address_in(activate_ACC_read_address), .activate_read_blocked_out(activate_ACC_read_blocked), .read_data_out(ACC_read_data));

    // -- accumulators -> bias -> activation (sequenced by ACT) ----------------------
    logic                     bias_enable, relu_enable, multiply_enable;
    logic [ARRAY_SIZE*32-1:0] biased_row, activation_row, multiply_row;
    logic [ARRAY_SIZE*8-1:0]  quantized_row;

    bias #(.ARRAY_SIZE(ARRAY_SIZE)) u_bias (
        .row_in(ACC_read_data), .bias_row_in(bias_read_data), .bias_enable_in(bias_enable), .row_out(biased_row));

    activation #(.ARRAY_SIZE(ARRAY_SIZE)) u_activation (
        .clk(clk), .reset(reset),
        .row_in(biased_row), .relu_enable_in(relu_enable), .row_out(activation_row),
        .multiply_enable_in(multiply_enable), .multiply_row_in(multiply_row), .quantization_row_in(quantization_read_data), .quantized_row_out(quantized_row));

    // -- DDR3: WT's and LD's readers, ACT's writer, one master ------------------------
    logic                    weight_request_ready, weight_request, weight_row_valid, weight_row_pop;
    logic [31:0]             weight_request_address, weight_request_beats, weight_request_rows;
    logic [WEIGHT_LANES*ARRAY_SIZE*8-1:0] weight_row_data;
    logic                    load_request_ready, load_request, load_row_valid, load_row_pop;
    logic [31:0]             load_request_address, load_request_beats, load_request_rows;
    logic [3:0]              load_request_skip;
    logic [ARRAY_SIZE*8-1:0] load_DDR_row;
    logic                    DDR_word_valid, DDR_writer_full, DDR_writer_idle;
    logic [31:0]             DDR_word_address;

    logic [31:0]  weight_memory_address, load_memory_address, activate_memory_address;
    logic         weight_memory_read, load_memory_read, activate_memory_write;
    logic [7:0]   weight_memory_burstcount, load_memory_burstcount;
    logic         weight_memory_waitrequest, load_memory_waitrequest, activate_memory_waitrequest;
    logic         weight_memory_readdatavalid, load_memory_readdatavalid;
    logic [DDR_BEAT_BITS-1:0]   activate_memory_writedata;
    logic [DDR_BEAT_BITS/8-1:0] activate_memory_byteenable;

    // a "row" for WT is WEIGHT_LANES weight rows: one 16-byte beat at N = 8, lanes = 2
    ddr_reader #(.ARRAY_SIZE(ARRAY_SIZE * WEIGHT_LANES), .BEAT_BITS(DDR_BEAT_BITS)) u_weight_reader (
        .clk(clk), .reset(reset), .bus_reset(bus_reset),
        .request_ready_out(weight_request_ready), .request_valid_in(weight_request), .request_address_in(weight_request_address),
        .request_beats_in(weight_request_beats), .request_skip_in(4'd0), .request_rows_in(weight_request_rows),
        .row_valid_out(weight_row_valid), .row_data_out(weight_row_data), .row_pop_in(weight_row_pop),
        .memory_address_out(weight_memory_address), .memory_read_out(weight_memory_read), .memory_burstcount_out(weight_memory_burstcount),
        .memory_waitrequest_in(weight_memory_waitrequest), .memory_readdata_in(memory_readdata_in), .memory_readdatavalid_in(weight_memory_readdatavalid));

    // RD_DDR_UB moves a row a cycle into the UB: a small FIFO is plenty
    ddr_reader #(.ARRAY_SIZE(ARRAY_SIZE), .FIFO_DEPTH(64), .BEAT_BITS(DDR_BEAT_BITS)) u_load_reader (
        .clk(clk), .reset(reset), .bus_reset(bus_reset),
        .request_ready_out(load_request_ready), .request_valid_in(load_request), .request_address_in(load_request_address),
        .request_beats_in(load_request_beats), .request_skip_in(load_request_skip), .request_rows_in(load_request_rows),
        .row_valid_out(load_row_valid), .row_data_out(load_DDR_row), .row_pop_in(load_row_pop),
        .memory_address_out(load_memory_address), .memory_read_out(load_memory_read), .memory_burstcount_out(load_memory_burstcount),
        .memory_waitrequest_in(load_memory_waitrequest), .memory_readdata_in(memory_readdata_in), .memory_readdatavalid_in(load_memory_readdatavalid));

    // writes in progress outlive CTRL.RESET, like reads: only the power-on reset clears them
    ddr_writer #(.BEAT_BITS(DDR_BEAT_BITS)) u_writer (
        .clk(clk), .reset(bus_reset),
        .word_valid_in(DDR_word_valid), .word_address_in(DDR_word_address[31:2]), .word_in(activate_output_word),
        .full_out(DDR_writer_full), .idle_out(DDR_writer_idle),
        .memory_address_out(activate_memory_address), .memory_write_out(activate_memory_write),
        .memory_writedata_out(activate_memory_writedata), .memory_byteenable_out(activate_memory_byteenable),
        .memory_waitrequest_in(activate_memory_waitrequest));

    memory_arbiter #(.BEAT_BITS(DDR_BEAT_BITS)) u_memory_arbiter (
        .clk(clk), .reset(bus_reset),
        .weight_address_in(weight_memory_address), .weight_read_in(weight_memory_read), .weight_burstcount_in(weight_memory_burstcount),
        .weight_waitrequest_out(weight_memory_waitrequest), .weight_readdatavalid_out(weight_memory_readdatavalid),
        .load_address_in(load_memory_address), .load_read_in(load_memory_read), .load_burstcount_in(load_memory_burstcount),
        .load_waitrequest_out(load_memory_waitrequest), .load_readdatavalid_out(load_memory_readdatavalid),
        .activate_address_in(activate_memory_address), .activate_write_in(activate_memory_write),
        .activate_writedata_in(activate_memory_writedata), .activate_byteenable_in(activate_memory_byteenable),
        .activate_waitrequest_out(activate_memory_waitrequest),
        .memory_address_out(memory_address_out), .memory_read_out(memory_read_out), .memory_write_out(memory_write_out),
        .memory_burstcount_out(memory_burstcount_out), .memory_writedata_out(memory_writedata_out),
        .memory_byteenable_out(memory_byteenable_out), .memory_waitrequest_in(memory_waitrequest_in),
        .memory_readdatavalid_in(memory_readdatavalid_in));

    // -- engines -------------------------------------------------------------------
    logic [3:0] engine_idle, engine_blocked;
    logic       performance_beat, performance_weight_stall, performance_sync_stall;

    load_engine #(.ARRAY_SIZE(ARRAY_SIZE), .WMEM_ADDRESS_WIDTH(WMEM_ADDRESS_WIDTH), .UB_ADDRESS_WIDTH(UB_ADDRESS_WIDTH), .PARAMETER_ADDRESS_WIDTH(PARAMETER_ADDRESS_WIDTH),
                  .BEAT_BYTES(DDR_BEAT_BITS / 8)) u_load_engine (
        .clk(clk), .reset(reset),
        .queue_valid_in(!queue_empty[ENGINE_LOAD]), .queue_entry_in(queue_head[ENGINE_LOAD]), .queue_pop_out(queue_pop[ENGINE_LOAD]),
        .completed_in(completed), .instruction_done_out(instruction_done[ENGINE_LOAD]),
        .data_valid_in(!data_empty), .UB_write_blocked_in(activate_UB_write_enable), .data_in(data_head), .data_pop_out(data_pop),
        .DDR_request_ready_in(load_request_ready), .DDR_request_out(load_request), .DDR_request_address_out(load_request_address),
        .DDR_request_beats_out(load_request_beats), .DDR_request_skip_out(load_request_skip), .DDR_request_rows_out(load_request_rows),
        .DDR_row_valid_in(load_row_valid), .DDR_row_data_in(load_DDR_row), .DDR_row_pop_out(load_row_pop), .blocked_out(engine_blocked[ENGINE_LOAD]),
        .WMEM_write_enable_out(WMEM_write_enable), .WMEM_write_address_out(WMEM_write_address), .UB_write_enable_out(load_UB_write_enable), .UB_write_address_out(load_UB_write_address),
        .row_write_data_out(load_row_data), .bias_write_enable_out(bias_write_enable), .quantization_write_enable_out(quantization_write_enable),
        .parameter_write_address_out(parameter_write_address), .parameter_write_data_out(parameter_write_data), .idle_out(engine_idle[ENGINE_LOAD]));

    weight_engine #(.ARRAY_SIZE(ARRAY_SIZE), .WMEM_ADDRESS_WIDTH(WMEM_GROUP_WIDTH), .FILL_ROWS(WEIGHT_LANES),
                    .SLOT_WIDTH(SLOT_WIDTH), .BEAT_BYTES(DDR_BEAT_BITS / 8)) u_weight_engine (
        .clk(clk), .reset(reset),
        .queue_valid_in(!queue_empty[ENGINE_WEIGHT]), .queue_entry_in(queue_head[ENGINE_WEIGHT]), .queue_pop_out(queue_pop[ENGINE_WEIGHT]),
        .completed_in(completed), .instruction_done_out(instruction_done[ENGINE_WEIGHT]),
        .WMEM_read_address_out(WMEM_read_address), .WMEM_read_data_in(WMEM_read_data),
        .DDR_request_ready_in(weight_request_ready), .DDR_request_out(weight_request), .DDR_request_address_out(weight_request_address),
        .DDR_request_beats_out(weight_request_beats), .DDR_request_rows_out(weight_request_rows),
        .DDR_row_valid_in(weight_row_valid), .DDR_row_data_in(weight_row_data), .DDR_row_pop_out(weight_row_pop),
        .fill_ready_in(fill_ready), .fill_slot_next_in(fill_slot_next), .fill_advance_out(fill_advance),
        .fill_write_enable_out(fill_write_enable), .fill_slot_out(fill_slot), .fill_row_out(fill_row), .fill_data_out(fill_data),
        .blocked_out(engine_blocked[ENGINE_WEIGHT]), .idle_out(engine_idle[ENGINE_WEIGHT]));

    matmul_engine #(.ARRAY_SIZE(ARRAY_SIZE), .UB_ADDRESS_WIDTH(UB_ADDRESS_WIDTH), .ACC_ADDRESS_WIDTH(ACC_ADDRESS_WIDTH),
                    .WEIGHT_LANES(WEIGHT_LANES), .SLOTS(WEIGHT_SLOTS)) u_matmul_engine (
        .clk(clk), .reset(reset),
        .queue_valid_in(!queue_empty[ENGINE_MATMUL]), .queue_entry_in(queue_head[ENGINE_MATMUL]), .queue_pop_out(queue_pop[ENGINE_MATMUL]),
        .completed_in(completed), .instruction_done_out(instruction_done[ENGINE_MATMUL]),
        .slots_in(weight_slots), .slot_full_in(slot_full), .drain_slot_in(drain_slot), .tile_take_out(tile_take),
        .UB_read_enable_out(matmul_UB_read_enable), .UB_read_address_out(matmul_UB_read_address), .activation_valid_out(activation_valid), .activation_weight_flip_out(activation_weight_flip),
        .weight_valid_out(weight_valid), .weight_row_select_out(weight_row_select), .weight_data_out(weight_data),
        .tag_push_out(tag_push), .tag_out(row_tag), .row_written_in(row_written),
        .performance_beat_out(performance_beat), .performance_weight_stall_out(performance_weight_stall), .performance_sync_stall_out(performance_sync_stall),
        .blocked_out(engine_blocked[ENGINE_MATMUL]), .idle_out(engine_idle[ENGINE_MATMUL]));

    activate_engine #(.ARRAY_SIZE(ARRAY_SIZE), .UB_ADDRESS_WIDTH(UB_ADDRESS_WIDTH), .ACC_ADDRESS_WIDTH(ACC_ADDRESS_WIDTH), .PARAMETER_ADDRESS_WIDTH(PARAMETER_ADDRESS_WIDTH)) u_activate_engine (
        .clk(clk), .reset(reset),
        .queue_valid_in(!queue_empty[ENGINE_ACTIVATE]), .queue_entry_in(queue_head[ENGINE_ACTIVATE]), .queue_pop_out(queue_pop[ENGINE_ACTIVATE]),
        .completed_in(completed), .instruction_done_out(instruction_done[ENGINE_ACTIVATE]),
        .ACC_read_address_out(activate_ACC_read_address), .ACC_read_blocked_in(activate_ACC_read_blocked),
        .parameter_read_address_out(parameter_read_address), .bias_enable_out(bias_enable), .relu_enable_out(relu_enable), .activation_row_in(activation_row),
        .multiply_enable_out(multiply_enable), .multiply_row_out(multiply_row), .quantized_row_in(quantized_row),
        .UB_write_enable_out(activate_UB_write_enable), .UB_write_address_out(activate_UB_write_address), .UB_write_data_out(activate_UB_write_data),
        .UB_read_enable_out(activate_UB_read_enable), .UB_read_address_out(activate_UB_read_address), .UB_read_blocked_in(matmul_UB_read_enable), .UB_read_data_in(UB_read_data),
        .output_push_out(output_push), .output_word_out(activate_output_word), .output_full_in(output_full),
        .DDR_word_valid_out(DDR_word_valid), .DDR_word_address_out(DDR_word_address), .DDR_full_in(DDR_writer_full), .DDR_idle_in(DDR_writer_idle),
        .blocked_out(engine_blocked[ENGINE_ACTIVATE]), .idle_out(engine_idle[ENGINE_ACTIVATE]));

    assign idle_out = instruction_empty && engine_idle == 4'hF && !fence_pending;

    // -- profiler: every dispatch, pop and completion, timestamped ----------------
    logic [3:0] queue_popped;
    always_comb
        for (int engine = 0; engine < 4; engine++)
            queue_popped[engine] = queue_pop[engine] && !queue_empty[engine];

    profiler u_profiler (
        .clk(clk), .reset(bus_reset), .clear_in(clear_profile_in),
        .dispatch_in(instruction_pop), .pop_in(queue_popped), .done_in(instruction_done), .blocked_in(engine_blocked),
        .read_in(profile_read_in), .word_out(profile_word_out), .level_out(profile_level_out), .dropped_out(profile_dropped_out));

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
