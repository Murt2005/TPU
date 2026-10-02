`timescale 1ns / 1ps

// DDR3 rows for an engine: burst reads of 128-bit beats into a prefetch FIFO,
// unpacked into N-byte rows (WT's weight rows, LD's UB entries). a request names
// whole beats, the rows to skip in its first beat and the rows to deliver; the
// rest of its last beat is dropped. a new request is taken once the previous
// one's reads are all issued, so the next one's reads follow straight on.
// reads issue only while the FIFO has room for everything in flight, because the
// bus can't be told to wait with read data. CTRL.RESET (reset) can land with reads
// in flight, or with a burst the bus is still holding off: Avalon wants that one
// kept up until it's taken. so bus_reset alone clears the in-flight count, the
// held burst still issues, and every beat of an abandoned request is dropped
module ddr_reader #(
    parameter int ARRAY_SIZE = 8,
    parameter int FIFO_DEPTH = 256,          // 16-byte beats
    parameter int BURST      = 16,           // beats per burst, at most
    parameter int REQUESTS   = 4             // taken but not yet delivered
) (
    input  logic                    clk,
    input  logic                    reset,                       // CTRL.RESET or power-on
    input  logic                    bus_reset,                   // power-on only

    output logic                    request_ready_out,
    input  logic                    request_valid_in,            // taken when ready
    input  logic [31:0]             request_address_in,          // byte address, 16-byte aligned
    input  logic [31:0]             request_beats_in,
    input  logic [3:0]              request_skip_in,             // rows before the first one delivered
    input  logic [31:0]             request_rows_in,

    output logic                    row_valid_out,
    output logic [ARRAY_SIZE*8-1:0] row_data_out,                // row byte c = DDR3 byte c
    input  logic                    row_pop_in,

    output logic [31:0]             memory_address_out,
    output logic                    memory_read_out,
    output logic [7:0]              memory_burstcount_out,
    input  logic                    memory_waitrequest_in,
    input  logic [127:0]            memory_readdata_in,
    input  logic                    memory_readdatavalid_in
);

    localparam int ROW_BITS      = ARRAY_SIZE * 8;
    localparam int ROWS_PER_BEAT = 128 / ROW_BITS;
    localparam int COUNT_WIDTH   = $clog2(FIFO_DEPTH) + 1;

    initial begin
        if (128 % ROW_BITS != 0) $fatal(1, "ddr_reader: a %0d-bit row must divide a 128-bit beat", ROW_BITS);
        if (BURST < 1 || BURST > 128 || BURST > FIFO_DEPTH) $fatal(1, "ddr_reader: BURST=%0d", BURST);
    end

    // -- command side ---------------------------------------------------------------
    logic [31:0]            next_address, beats_to_issue;
    logic [7:0]             burst_beats;
    logic [COUNT_WIDTH-1:0] in_flight, discard, fifo_count;
    logic                   command_accepted, beat_kept, requests_full, requests_empty;
    logic                   abandoned, held;     // a burst still up for a request CTRL.RESET dropped

    assign request_ready_out = beats_to_issue == 0 && !requests_full && !reset;

    assign burst_beats = beats_to_issue < 32'(BURST) ? 8'(beats_to_issue) : 8'(BURST);
    // everything in flight lands in the FIFO, so it must fit alongside this burst.
    // a held burst stays up: credit only grows while it waits
    assign memory_read_out       = beats_to_issue != 0
                                   && (abandoned || 32'(fifo_count) + 32'(in_flight) + 32'(burst_beats) <= 32'(FIFO_DEPTH));
    assign memory_address_out    = next_address;
    assign memory_burstcount_out = burst_beats;
    assign command_accepted      = memory_read_out && !memory_waitrequest_in;
    assign held                  = memory_read_out && memory_waitrequest_in;
    assign beat_kept             = memory_readdatavalid_in && discard == 0 && !reset;

    // beats arrive in issue order, so the first `discard` of them are the abandoned ones
    always_ff @(posedge clk) begin
        if (bus_reset) begin
            in_flight <= '0;
            discard   <= '0;
        end else begin
            in_flight <= in_flight + (command_accepted ? COUNT_WIDTH'(burst_beats) : '0)
                                   - COUNT_WIDTH'(memory_readdatavalid_in);
            if (reset)
                discard <= in_flight + (command_accepted ? COUNT_WIDTH'(burst_beats) : '0)
                                     - COUNT_WIDTH'(memory_readdatavalid_in);
            else
                discard <= discard + (abandoned && command_accepted ? COUNT_WIDTH'(burst_beats) : '0)
                                   - COUNT_WIDTH'(memory_readdatavalid_in && discard != 0);
        end
    end

    always_ff @(posedge clk) begin
        if (bus_reset) begin
            next_address   <= '0;
            beats_to_issue <= '0;
            abandoned      <= 1'b0;
        end else if (reset) begin
            beats_to_issue <= held ? 32'(burst_beats) : '0;
            abandoned      <= held;
        end else if (abandoned) begin
            if (command_accepted) begin
                beats_to_issue <= '0;
                abandoned      <= 1'b0;
            end
        end else if (request_valid_in && request_ready_out) begin
            next_address   <= request_address_in;
            beats_to_issue <= request_beats_in;
        end else if (command_accepted) begin
            next_address   <= next_address + {20'd0, burst_beats, 4'd0};
            beats_to_issue <= beats_to_issue - 32'(burst_beats);
        end
    end

    // each request's skip and row count, in order, for the unpacker
    logic [35:0] request_head;
    logic        request_done;
    fifo #(.WIDTH(36), .DEPTH(REQUESTS)) u_requests (
        .clk(clk), .reset(reset),
        .write_enable_in(request_valid_in && request_ready_out), .write_data_in({request_skip_in, request_rows_in}),
        .read_enable_in(request_done), .read_data_out(request_head), .full_out(requests_full), .empty_out(requests_empty));

    // -- prefetch FIFO and row unpacking ---------------------------------------
    logic         fifo_empty, fifo_full, beat_done, active, row_popped, last_row;
    logic [127:0] beat;
    logic [3:0]   row_in_beat, current_row;
    logic [31:0]  rows_left, current_left;

    // the first row of a request comes straight from its entry, without a bubble
    assign current_row  = active ? row_in_beat : request_head[35:32];
    assign current_left = active ? rows_left : request_head[31:0];
    assign row_valid_out = !fifo_empty && (active || !requests_empty);
    assign row_data_out  = beat[ROW_BITS*current_row[$clog2(ROWS_PER_BEAT+1)-1:0] +: ROW_BITS];
    assign row_popped    = row_pop_in && row_valid_out;
    assign last_row      = current_left == 32'd1;
    assign beat_done     = row_popped && (current_row == 4'(ROWS_PER_BEAT - 1) || last_row);
    assign request_done  = row_popped && last_row;

    block_fifo #(.WIDTH(128), .DEPTH(FIFO_DEPTH)) u_prefetch (
        .clk(clk), .reset(reset), .write_enable_in(beat_kept), .write_data_in(memory_readdata_in),
        .read_enable_in(beat_done), .read_data_out(beat), .full_out(fifo_full), .empty_out(fifo_empty));

    always_ff @(posedge clk) begin
        if (reset) begin
            fifo_count  <= '0;
            active      <= 1'b0;
            row_in_beat <= '0;
            rows_left   <= '0;
        end else begin
            fifo_count <= fifo_count + COUNT_WIDTH'(beat_kept) - COUNT_WIDTH'(beat_done);
            if (row_popped) begin
                active      <= !last_row;
                row_in_beat <= beat_done ? 4'd0 : current_row + 4'd1;
                rows_left   <= current_left - 32'd1;
            end
        end
    end

`ifndef SYNTHESIS
    // the credit check above makes overflow impossible
    always_ff @(posedge clk)
        if (!reset && beat_kept && fifo_full) $fatal(1, "ddr_reader: prefetch FIFO overflow");
`endif

endmodule
