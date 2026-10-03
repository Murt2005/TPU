`timescale 1ns / 1ps

import tpu_pkg::*;

// MM engine: overlapped tiles. each window of max(m, N / WEIGHT_LANES) cycles streams
// one tile's m activation rows, and starts streaming the next tile's weight rows into
// weight_next: row r reaches PE row r r cycles after the stream starts, in step with
// the activation wavefront, so a stream lasts N cycles whatever the window. a stream
// starts N cycles before its window ends, or at the window's start when the window is
// shorter; streams that overlap go out on separate lanes of the mmu's weight bus. the
// next tile's first row flips them in. a tile missing when its stream should start
// freezes the window (WSTALL), which only ever widens the gaps the PEs rely on; streams
// already running carry on. control only: tpu_core wires the UB, systolic data
// setup, mmu and accumulator
module matmul_engine #(
    parameter int ARRAY_SIZE        = 8,
    parameter int UB_ADDRESS_WIDTH  = 14,
    parameter int ACC_ADDRESS_WIDTH = 10,
    parameter int WEIGHT_LANES      = 1,                     // weight rows a cycle, at most
    parameter int SLOTS             = WEIGHT_LANES + 1,      // the weight FIFO's
    parameter int SLOT_WIDTH        = SLOTS > 2 ? $clog2(SLOTS) : 1
) (
    input  logic                         clk,
    input  logic                         reset,

    input  logic                         queue_valid_in,
    input  logic [QUEUE_ENTRY_WIDTH-1:0] queue_entry_in,
    output logic                         queue_pop_out,
    input  logic [63:0]                  completed_in,
    output logic                         instruction_done_out,

    input  logic [SLOTS-1:0][ARRAY_SIZE-1:0][ARRAY_SIZE*8-1:0] slots_in,                 // weight_fifo
    input  logic [SLOTS-1:0]              slot_full_in,
    input  logic [SLOT_WIDTH-1:0]         drain_slot_in,
    output logic                          tile_take_out,

    output logic                          UB_read_enable_out,         // always granted
    output logic [UB_ADDRESS_WIDTH-1:0]   UB_read_address_out,
    output logic                          activation_valid_out,       // the UB row read last cycle goes in now
    output logic                          activation_weight_flip_out, // ... and it's a tile's first row: flip

    output logic [WEIGHT_LANES-1:0]                            weight_valid_out,       // a weight row per lane, onto the
    output logic [WEIGHT_LANES-1:0][$clog2(ARRAY_SIZE)-1:0]    weight_row_select_out,  // mmu's row-select bus
    output logic signed [WEIGHT_LANES-1:0][ARRAY_SIZE-1:0][7:0] weight_data_out,

    output logic                       tag_push_out,                 // accumulator: where each issued row goes
    output logic [ACC_ADDRESS_WIDTH:0] tag_out,
    input  logic                       row_written_in,

    output logic                       performance_beat_out,
    output logic                       performance_weight_stall_out,
    output logic                       performance_sync_stall_out,
    output logic                       blocked_out,                  // has work it can't advance (profiler)
    output logic                       idle_out
);

    localparam int ROW_SELECT_WIDTH = $clog2(ARRAY_SIZE);
    localparam int MINIMUM_WINDOW   = ARRAY_SIZE / WEIGHT_LANES;
    localparam int LANE_WIDTH       = WEIGHT_LANES > 1 ? $clog2(WEIGHT_LANES) : 1;

    initial begin
        if (ARRAY_SIZE % WEIGHT_LANES != 0 || MINIMUM_WINDOW < 2)
            $fatal(1, "matmul_engine: WEIGHT_LANES=%0d must divide ARRAY_SIZE=%0d and leave windows of 2 cycles or more",
                   WEIGHT_LANES, ARRAY_SIZE);
    end

    logic [63:0] instruction, wait_snapshot;
    assign instruction   = queue_entry_in[63:0];
    assign wait_snapshot = queue_entry_in[127:64];
    logic [5:0] opcode;
    assign opcode = instruction[63:58];

    typedef enum logic [1:0] {S_IDLE, S_RUN, S_DRAIN} state_t;
    state_t state;

    logic        accumulate;
    logic [8:0]  activation_rows;
    logic [12:0] k_tiles, k_tile_index;
    logic [15:0] UB_chunk_base, UB_base;
    logic [15:0] ACC_base;
    logic        window_has_activations, window_has_weights; // this window streams a tile / loads the next
    logic [31:0] weight_tiles_left;                          // tiles whose weights are still to load
    logic [8:0]  window_position;
    logic [7:0]  rows_in_flight;                             // rows issued, not yet written to ACC

    logic [8:0] window_length, stream_start_position;
    assign window_length         = (window_has_activations && activation_rows > 9'(MINIMUM_WINDOW)) ? activation_rows : 9'(MINIMUM_WINDOW);
    assign stream_start_position = window_length > 9'(ARRAY_SIZE) ? window_length - 9'(ARRAY_SIZE) : 9'd0;

    // weight streams: up to WEIGHT_LANES at once, one per lane, each N cycles of rows
    // from one weight FIFO slot. they start in tile order, so they end in it too, and
    // the oldest stream's slot is always the FIFO's drain slot
    logic [WEIGHT_LANES-1:0]                       stream_active;
    logic [WEIGHT_LANES-1:0][ROW_SELECT_WIDTH-1:0] stream_row;
    logic [WEIGHT_LANES-1:0][SLOT_WIDTH-1:0]       stream_slot;
    logic [LANE_WIDTH-1:0]                         next_lane;
    logic [SLOT_WIDTH-1:0]                         next_slot;
    localparam int RUNNING_WIDTH = $clog2(WEIGHT_LANES + 1);
    logic [RUNNING_WIDTH-1:0]                      streams_running;
    always_comb begin
        streams_running = '0;
        for (int k = 0; k < WEIGHT_LANES; k++) streams_running += RUNNING_WIDTH'(stream_active[k]);
        next_slot = SLOT_WIDTH'((32'(drain_slot_in) + 32'(streams_running)) % SLOTS);
    end

    logic activation_issue_now, stream_due, stream_start, window_frozen, window_advance, window_end;
    assign activation_issue_now = window_has_activations && window_position < activation_rows;
    assign stream_due           = state == S_RUN && window_has_weights && window_position == stream_start_position;
    assign window_frozen        = stream_due && !slot_full_in[next_slot];
    assign window_advance       = state == S_RUN && !window_frozen;
    assign window_end           = window_advance && window_position == window_length - 9'd1;
    assign stream_start         = stream_due && slot_full_in[next_slot];

    // this cycle's row on each lane: a running stream's next, or row 0 of one starting
    logic [WEIGHT_LANES-1:0]                       lane_issue, lane_last;
    logic [WEIGHT_LANES-1:0][ROW_SELECT_WIDTH-1:0] lane_row;
    logic [WEIGHT_LANES-1:0][SLOT_WIDTH-1:0]       lane_slot;
    always_comb
        for (int k = 0; k < WEIGHT_LANES; k++) begin
            lane_issue[k] = stream_active[k] || (stream_start && next_lane == LANE_WIDTH'(k));
            lane_row[k]   = stream_active[k] ? stream_row[k] : '0;
            lane_slot[k]  = stream_active[k] ? stream_slot[k] : next_slot;
            lane_last[k]  = lane_issue[k] && lane_row[k] == ROW_SELECT_WIDTH'(ARRAY_SIZE - 1);
        end

    logic                                                  activation_valid_delayed, activation_weight_flip_delayed;
    logic        [WEIGHT_LANES-1:0]                        weight_register_valid;
    logic        [WEIGHT_LANES-1:0][ROW_SELECT_WIDTH-1:0]  weight_register_row;
    logic signed [WEIGHT_LANES-1:0][ARRAY_SIZE-1:0][7:0]   weight_register_data;
    assign activation_valid_out       = activation_valid_delayed;
    assign activation_weight_flip_out = activation_weight_flip_delayed;
    assign weight_valid_out           = weight_register_valid;
    assign weight_row_select_out      = weight_register_row;
    assign weight_data_out            = weight_register_data;

    // -- control -----------------------------------------------------------
    assign UB_read_enable_out  = window_advance && activation_issue_now;
    assign UB_read_address_out = UB_ADDRESS_WIDTH'(UB_chunk_base + 16'(window_position));
    assign tag_push_out        = UB_read_enable_out;
    assign tag_out             = {(k_tile_index == 13'd0) && !accumulate, ACC_ADDRESS_WIDTH'(ACC_base + 16'(window_position))};
    assign tile_take_out       = lane_last != '0;          // a stream sends its last row: its slot can refill

    logic wait_satisfied;
    assign wait_satisfied = wait_counts_reached(instruction[51:48], wait_snapshot, completed_in);
    assign queue_pop_out  = queue_valid_in && state == S_IDLE && (opcode != OPCODE_WAIT || wait_satisfied);
    assign idle_out       = state == S_IDLE && !queue_valid_in;

    assign performance_beat_out         = UB_read_enable_out;
    assign performance_weight_stall_out = state == S_RUN && window_frozen;
    assign performance_sync_stall_out   = queue_valid_in && state == S_IDLE && opcode == OPCODE_WAIT && !wait_satisfied;
    assign blocked_out                  = performance_weight_stall_out || performance_sync_stall_out;

    always_ff @(posedge clk) begin
        if (reset) begin
            state                          <= S_IDLE;
            accumulate                     <= 1'b0;
            activation_rows                <= '0;
            k_tiles                        <= '0;
            k_tile_index                   <= '0;
            UB_chunk_base                  <= '0;
            UB_base                        <= '0;
            ACC_base                       <= '0;
            window_has_activations         <= 1'b0;
            window_has_weights             <= 1'b0;
            weight_tiles_left              <= '0;
            window_position                <= '0;
            rows_in_flight                 <= '0;
            activation_valid_delayed       <= 1'b0;
            activation_weight_flip_delayed <= 1'b0;
            weight_register_valid          <= '0;
            weight_register_row            <= '0;
            weight_register_data           <= '0;
            stream_active                  <= '0;
            stream_row                     <= '0;
            stream_slot                    <= '0;
            next_lane                      <= '0;
            instruction_done_out           <= 1'b0;
        end else begin
            instruction_done_out           <= 1'b0;
            activation_valid_delayed       <= UB_read_enable_out;
            activation_weight_flip_delayed <= window_position == 9'd0;

            // weight rows registered to line up with the UB read latency
            for (int k = 0; k < WEIGHT_LANES; k++) begin
                weight_register_valid[k] <= lane_issue[k];
                weight_register_row[k]   <= lane_row[k];
                for (int column = 0; column < ARRAY_SIZE; column++)
                    weight_register_data[k][column] <= slots_in[lane_slot[k]][lane_row[k]][8*column +: 8];
                if (lane_issue[k]) begin
                    stream_active[k] <= !lane_last[k];
                    stream_row[k]    <= lane_row[k] + ROW_SELECT_WIDTH'(1);
                    stream_slot[k]   <= lane_slot[k];
                end
            end
            if (stream_start)
                next_lane <= next_lane == LANE_WIDTH'(WEIGHT_LANES - 1) ? '0 : next_lane + LANE_WIDTH'(1);

            rows_in_flight <= rows_in_flight + 8'(tag_push_out) - 8'(row_written_in);

            case (state)
                S_IDLE: if (queue_pop_out) begin
                    if (opcode == OPCODE_MATMUL) begin
                        accumulate             <= instruction[57];
                        activation_rows        <= 9'(instruction[55:48]) + 9'd1;
                        k_tiles                <= 13'(instruction[47:36]) + 13'd1;
                        ACC_base               <= 16'(instruction[25:16]);
                        UB_base                <= 16'(instruction[15:2]);
                        UB_chunk_base          <= 16'(instruction[15:2]);
                        k_tile_index           <= '0;
                        window_has_activations <= 1'b0;
                        window_has_weights     <= 1'b1;
                        weight_tiles_left      <= 32'(24'(11'(instruction[35:26]) + 11'd1) * 24'(13'(instruction[47:36]) + 13'd1));
                        window_position        <= '0;
                        state                  <= S_RUN;
                    end else begin
                        instruction_done_out <= 1'b1;            // WAIT
                    end
                end
                S_RUN: if (window_advance) begin
                    window_position <= window_position + 9'd1;
                    if (window_end) begin
                        window_position <= '0;
                        if (window_has_activations) begin
                            if (k_tile_index == k_tiles - 13'd1) begin
                                k_tile_index  <= '0;
                                UB_chunk_base <= UB_base;
                                ACC_base      <= ACC_base + 16'(activation_rows);
                            end else begin
                                k_tile_index  <= k_tile_index + 13'd1;
                                UB_chunk_base <= UB_chunk_base + 16'(activation_rows);
                            end
                        end
                        window_has_activations <= window_has_weights;
                        if (window_has_weights)
                            weight_tiles_left <= weight_tiles_left - 32'd1;
                        window_has_weights <= window_has_weights && weight_tiles_left > 32'd1;
                        if (!window_has_weights)
                            state <= S_DRAIN;
                    end
                end
                S_DRAIN: if (rows_in_flight == 8'd0 && stream_active == '0) begin
                    instruction_done_out <= 1'b1;
                    state                <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
