`timescale 1ns / 1ps

import tpu_pkg::*;

// WT engine: SET_WBASE, and the weight half of MATMUL: tiles into the weight FIFO's
// slots, FILL_ROWS rows per cycle, back to back across tiles while a slot is free. rows
// come from WMEM, or with wsrc=1 from DDR3 through ddr_reader: tile t is the N*N
// bytes at DDR3 byte t*N*N.
// two stages. fetch pops the queue, settles WAITs and WBASE, and hands a wsrc=1
// MATMUL's whole tile range to the reader as soon as the reader has issued the
// previous one's reads, so DDR3's latency hides behind the MATMUL before it. fill
// moves the rows. every instruction passes through a job FIFO between them and
// completes in fill, in order: a WAIT fetch has passed can't complete ahead of the
// MATMUL before it. a WAIT still holds back the reads of every MATMUL after it
module weight_engine #(
    parameter int ARRAY_SIZE         = 8,
    parameter int WMEM_ADDRESS_WIDTH = 13,          // of a group of FILL_ROWS rows
    parameter int JOBS               = 4,
    parameter int FILL_ROWS          = 1,           // rows a cycle: one WMEM word, one ddr_reader row
    parameter int SLOT_WIDTH         = 1,
    parameter int BEAT_BYTES         = 16          // a tile is a whole number of beats
) (
    input  logic                          clk,
    input  logic                          reset,

    input  logic                          queue_valid_in,
    input  logic [QUEUE_ENTRY_WIDTH-1:0]  queue_entry_in,
    output logic                          queue_pop_out,
    input  logic [63:0]                   completed_in,
    output logic                          instruction_done_out,

    output logic [WMEM_ADDRESS_WIDTH-1:0] WMEM_read_address_out,
    input  logic [FILL_ROWS*ARRAY_SIZE*8-1:0] WMEM_read_data_in, // one cycle after the address

    input  logic                          DDR_request_ready_in,  // ddr_reader
    output logic                          DDR_request_out,
    output logic [31:0]                   DDR_request_address_out,
    output logic [31:0]                   DDR_request_beats_out,
    output logic [31:0]                   DDR_request_rows_out,
    input  logic                          DDR_row_valid_in,
    input  logic [FILL_ROWS*ARRAY_SIZE*8-1:0] DDR_row_data_in,  // FILL_ROWS weight rows
    output logic                          DDR_row_pop_out,

    input  logic                          fill_ready_in,         // weight_fifo
    input  logic [SLOT_WIDTH-1:0]         fill_slot_next_in,
    output logic                          fill_advance_out,
    output logic                          fill_write_enable_out,
    output logic [SLOT_WIDTH-1:0]         fill_slot_out,
    output logic [7:0]                    fill_row_out,
    output logic [FILL_ROWS*ARRAY_SIZE*8-1:0] fill_data_out,

    output logic                          blocked_out,           // has work it can't advance (profiler)
    output logic                          idle_out
);

    // a tile is N*N bytes, a whole number of 16-byte beats for N = 4, 8, 16
    localparam int TILE_BYTES = ARRAY_SIZE * ARRAY_SIZE;

    logic [63:0] instruction, wait_snapshot;
    assign instruction   = queue_entry_in[63:0];
    assign wait_snapshot = queue_entry_in[127:64];
    logic [5:0] opcode;
    assign opcode = instruction[63:58];

    // -- fetch ------------------------------------------------------------------
    logic [31:0] weight_base;
    logic [23:0] matmul_tile_count;
    logic        is_matmul, from_DDR_now, jobs_full, jobs_empty;
    assign matmul_tile_count = 24'(11'(instruction[35:26]) + 11'd1) * 24'(13'(instruction[47:36]) + 13'd1);
    assign is_matmul         = opcode == OPCODE_MATMUL;
    assign from_DDR_now      = is_matmul && instruction[56];

    assign queue_pop_out = queue_valid_in && !jobs_full
                           && (opcode != OPCODE_WAIT || wait_counts_reached(instruction[51:48], wait_snapshot, completed_in))
                           && (!from_DDR_now || DDR_request_ready_in);

    assign DDR_request_out         = queue_pop_out && from_DDR_now;
    assign DDR_request_address_out = weight_base * 32'(TILE_BYTES);
    initial if (TILE_BYTES % BEAT_BYTES != 0) $fatal(1, "weight_engine: a %0d-byte tile isn't whole %0d-byte beats", TILE_BYTES, BEAT_BYTES);
    assign DDR_request_beats_out   = 32'(matmul_tile_count) * 32'(TILE_BYTES / BEAT_BYTES);
    assign DDR_request_rows_out    = 32'(matmul_tile_count) * 32'(ARRAY_SIZE / FILL_ROWS);

    always_ff @(posedge clk) begin
        if (reset)
            weight_base <= '0;
        else if (queue_pop_out && opcode == OPCODE_SET_WBASE)
            weight_base <= instruction[31:0];
        else if (queue_pop_out && is_matmul)
            weight_base <= weight_base + 32'(matmul_tile_count);
    end

    // job: {MATMUL, from DDR3, first tile, tiles}; anything else just completes
    logic [57:0] job;
    logic        job_pop;
    fifo #(.WIDTH(58), .DEPTH(JOBS)) u_jobs (
        .clk(clk), .reset(reset), .write_enable_in(queue_pop_out),
        .write_data_in({is_matmul, from_DDR_now, weight_base, matmul_tile_count}),
        .read_enable_in(job_pop), .read_data_out(job), .full_out(jobs_full), .empty_out(jobs_empty));

    // -- fill -------------------------------------------------------------------
    logic [31:0] tiles_left;                                // tiles still to issue
    logic [31:0] tile_index;
    logic [7:0]  row_in_tile;
    logic        read_pending, read_is_last_row;
    logic [SLOT_WIDTH-1:0] read_slot;
    logic [7:0]  read_row;
    logic        from_DDR, read_from_DDR;                    // this MATMUL's source; the pending read's
    logic [FILL_ROWS*ARRAY_SIZE*8-1:0] DDR_row;
    localparam logic [7:0] LAST_GROUP = 8'(ARRAY_SIZE - FILL_ROWS);

    logic issuing_read;
    assign issuing_read = tiles_left != 0 && fill_ready_in && (!from_DDR || DDR_row_valid_in);
    assign job_pop      = !jobs_empty && tiles_left == 0 && !read_pending;

    assign DDR_row_pop_out       = issuing_read && from_DDR;
    assign fill_advance_out      = issuing_read && row_in_tile == LAST_GROUP;
    assign fill_write_enable_out = read_pending;
    assign fill_slot_out         = read_slot;
    assign fill_row_out          = read_row;
    assign fill_data_out         = read_from_DDR ? DDR_row : WMEM_read_data_in;

    assign WMEM_read_address_out = WMEM_ADDRESS_WIDTH'((tile_index * ARRAY_SIZE + 32'(row_in_tile)) / FILL_ROWS);
    assign idle_out              = !queue_valid_in && jobs_empty && tiles_left == 0 && !read_pending;
    // a WAIT (or the DDR3 reader) holding fetch, or a free slot waiting on DDR3 rows; a full
    // tile buffer is MM's pace, not a stall
    assign blocked_out           = (queue_valid_in && !jobs_full && !queue_pop_out)
                                   || (tiles_left != 0 && fill_ready_in && from_DDR && !DDR_row_valid_in);

    always_ff @(posedge clk) begin
        if (reset) begin
            tiles_left           <= '0;
            tile_index           <= '0;
            row_in_tile          <= '0;
            read_pending         <= 1'b0;
            read_slot            <= '0;
            read_is_last_row     <= 1'b0;
            read_row             <= '0;
            from_DDR             <= 1'b0;
            read_from_DDR        <= 1'b0;
            DDR_row              <= '0;
            instruction_done_out <= 1'b0;
        end else begin
            instruction_done_out <= 1'b0;

            if (job_pop) begin
                if (job[57]) begin                            // MATMUL
                    from_DDR    <= job[56];
                    tile_index  <= job[55:24];
                    tiles_left  <= 32'(job[23:0]);
                    row_in_tile <= '0;
                end else begin
                    instruction_done_out <= 1'b1;             // SET_WBASE, WAIT
                end
            end

            // one row read per cycle; the slot index flips as the last row issues
            read_pending     <= issuing_read;
            read_from_DDR    <= from_DDR;
            if (DDR_row_pop_out) DDR_row <= DDR_row_data_in;
            read_slot        <= fill_slot_next_in;
            read_row         <= row_in_tile;
            read_is_last_row <= issuing_read && row_in_tile == LAST_GROUP && tiles_left == 32'd1;
            if (issuing_read) begin
                if (row_in_tile == LAST_GROUP) begin
                    row_in_tile <= '0;
                    tile_index  <= tile_index + 32'd1;
                    tiles_left  <= tiles_left - 32'd1;
                end else begin
                    row_in_tile <= row_in_tile + 8'(FILL_ROWS);
                end
            end

            if (read_pending && read_row == LAST_GROUP && read_is_last_row)
                instruction_done_out <= 1'b1;
        end
    end

endmodule
