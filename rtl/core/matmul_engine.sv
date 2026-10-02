`timescale 1ns / 1ps

import tpu_pkg::*;

// MM engine: overlapped tiles. each window of max(m, N) cycles streams one tile's
// m activation rows and, in its last N cycles, the next tile's weight rows into
// weight_next; the next tile's first row flips them in. a missing tile freezes the
// whole window (WSTALL), which only ever widens the gaps the PEs rely on.
// control only: tpu_core wires the UB, systolic data setup, mmu and accumulator
module matmul_engine #(
    parameter int ARRAY_SIZE        = 8,
    parameter int UB_ADDRESS_WIDTH  = 14,
    parameter int ACC_ADDRESS_WIDTH = 10
) (
    input  logic                         clk,
    input  logic                         reset,

    input  logic                         queue_valid,
    input  logic [QUEUE_ENTRY_WIDTH-1:0] queue_entry,
    output logic                         queue_pop,
    input  logic [63:0]                  completed,
    output logic                         instruction_done,

    input  logic [ARRAY_SIZE-1:0][ARRAY_SIZE*8-1:0] tile,            // weight_fifo
    input  logic                          tile_full,
    output logic                          tile_take,

    output logic                          UB_read_enable,         // always granted
    output logic [UB_ADDRESS_WIDTH-1:0]   UB_read_address,
    output logic                          activation_valid,       // the UB row read last cycle goes in now
    output logic                          activation_weight_flip, // ... and it's a tile's first row: flip

    output logic                          weight_valid,           // the next tile's weight row, onto the
    output logic [$clog2(ARRAY_SIZE)-1:0] weight_row,             // mmu's row-select bus
    output logic signed [ARRAY_SIZE-1:0][7:0] weight_data,

    output logic                       tag_push,                 // accumulator: where each issued row goes
    output logic [ACC_ADDRESS_WIDTH:0] tag_in,
    input  logic                       row_written,

    output logic                       performance_beat,
    output logic                       performance_weight_stall,
    output logic                       performance_sync_stall,
    output logic                       idle
);

    localparam int ROW_SELECT_WIDTH = $clog2(ARRAY_SIZE);

    logic [63:0] instruction, wait_snapshot;
    assign instruction   = queue_entry[63:0];
    assign wait_snapshot = queue_entry[127:64];
    logic [5:0] opcode;
    assign opcode = instruction[63:58];

    typedef enum logic [1:0] {S_IDLE, S_RUN, S_DRAIN} state_t;
    state_t state;

    logic        accumulate;
    logic [8:0]  activation_rows;
    logic [12:0] k_tiles, k_tile;
    logic [15:0] chunk_base, UB_base;
    logic [15:0] ACC_base;
    logic        window_has_activations, window_has_weights; // this window streams a tile / loads the next
    logic [31:0] weight_tiles_left;                          // tiles whose weights are still to load
    logic [8:0]  window_position;
    logic [7:0]  rows_in_flight;                             // rows issued, not yet written to ACC

    logic [8:0] window_length, weight_window_start;
    assign window_length       = (window_has_activations && activation_rows > 9'(ARRAY_SIZE)) ? activation_rows : 9'(ARRAY_SIZE);
    assign weight_window_start = window_length - 9'(ARRAY_SIZE);

    logic activation_issue_now, weight_issue_now, window_frozen, advance, window_end;
    assign activation_issue_now = window_has_activations && window_position < activation_rows;
    assign weight_issue_now     = window_has_weights && window_position >= weight_window_start;
    assign window_frozen        = weight_issue_now && !tile_full;
    assign advance              = state == S_RUN && !window_frozen;
    assign window_end           = advance && window_position == window_length - 9'd1;

    logic                               activation_valid_delayed, activation_weight_flip_delayed;
    logic                               weight_register_valid;
    logic        [ROW_SELECT_WIDTH-1:0] weight_register_row;
    logic signed [ARRAY_SIZE-1:0] [7:0] weight_register_data;
    logic        [ROW_SELECT_WIDTH-1:0] weight_row_now;
    assign weight_row_now         = ROW_SELECT_WIDTH'(window_position - weight_window_start);
    assign activation_valid       = activation_valid_delayed;
    assign activation_weight_flip = activation_weight_flip_delayed;
    assign weight_valid           = weight_register_valid;
    assign weight_row             = weight_register_row;
    assign weight_data            = weight_register_data;

    // -- control -----------------------------------------------------------
    assign UB_read_enable  = advance && activation_issue_now;
    assign UB_read_address = UB_ADDRESS_WIDTH'(chunk_base + 16'(window_position));
    assign tag_push        = UB_read_enable;
    assign tag_in          = {(k_tile == 13'd0) && !accumulate, ACC_ADDRESS_WIDTH'(ACC_base + 16'(window_position))};
    assign tile_take       = advance && weight_issue_now && window_position == window_length - 9'd1;

    logic wait_satisfied;
    assign wait_satisfied = wait_counts_reached(instruction[51:48], wait_snapshot, completed);
    assign queue_pop      = queue_valid && state == S_IDLE && (opcode != OPCODE_WAIT || wait_satisfied);
    assign idle           = state == S_IDLE && !queue_valid;

    assign performance_beat         = UB_read_enable;
    assign performance_weight_stall = state == S_RUN && window_frozen;
    assign performance_sync_stall   = queue_valid && state == S_IDLE && opcode == OPCODE_WAIT && !wait_satisfied;

    always_ff @(posedge clk) begin
        if (reset) begin
            state                          <= S_IDLE;
            accumulate                     <= 1'b0;
            activation_rows                <= '0;
            k_tiles                        <= '0;
            k_tile                         <= '0;
            chunk_base                     <= '0;
            UB_base                        <= '0;
            ACC_base                       <= '0;
            window_has_activations         <= 1'b0;
            window_has_weights             <= 1'b0;
            weight_tiles_left              <= '0;
            window_position                <= '0;
            rows_in_flight                 <= '0;
            activation_valid_delayed       <= 1'b0;
            activation_weight_flip_delayed <= 1'b0;
            weight_register_valid          <= 1'b0;
            weight_register_row            <= '0;
            weight_register_data           <= '0;
            instruction_done               <= 1'b0;
        end else begin
            instruction_done               <= 1'b0;
            activation_valid_delayed       <= UB_read_enable;
            activation_weight_flip_delayed <= window_position == 9'd0;

            // weight row registered to line up with the UB read latency
            weight_register_valid <= advance && weight_issue_now;
            weight_register_row   <= weight_row_now;
            for (int column = 0; column < ARRAY_SIZE; column++)
                weight_register_data[column] <= tile[weight_row_now][8*column +: 8];

            rows_in_flight <= rows_in_flight + 8'(tag_push) - 8'(row_written);

            case (state)
                S_IDLE: if (queue_pop) begin
                    if (opcode == OPCODE_MATMUL) begin
                        accumulate             <= instruction[57];
                        activation_rows        <= 9'(instruction[55:48]) + 9'd1;
                        k_tiles                <= 13'(instruction[47:36]) + 13'd1;
                        ACC_base               <= 16'(instruction[25:16]);
                        UB_base                <= 16'(instruction[15:2]);
                        chunk_base             <= 16'(instruction[15:2]);
                        k_tile                 <= '0;
                        window_has_activations <= 1'b0;
                        window_has_weights     <= 1'b1;
                        weight_tiles_left      <= 32'(24'(11'(instruction[35:26]) + 11'd1) * 24'(13'(instruction[47:36]) + 13'd1));
                        window_position        <= '0;
                        state                  <= S_RUN;
                    end else begin
                        instruction_done <= 1'b1;            // WAIT
                    end
                end
                S_RUN: if (advance) begin
                    window_position <= window_position + 9'd1;
                    if (window_end) begin
                        window_position <= '0;
                        if (window_has_activations) begin
                            if (k_tile == k_tiles - 13'd1) begin
                                k_tile     <= '0;
                                chunk_base <= UB_base;
                                ACC_base   <= ACC_base + 16'(activation_rows);
                            end else begin
                                k_tile     <= k_tile + 13'd1;
                                chunk_base <= chunk_base + 16'(activation_rows);
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
                S_DRAIN: if (rows_in_flight == 8'd0) begin
                    instruction_done <= 1'b1;
                    state            <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
