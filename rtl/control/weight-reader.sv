`timescale 1ns / 1ps

// weights from DDR3 (MATMUL wsrc=1): a 128-bit Avalon-MM burst-read master in front
// of a prefetch FIFO, unpacked into weight rows for WT. WT requests a MATMUL's whole
// tile range; bursts issue only while the FIFO has room for everything in flight,
// because the bus can't be told to wait with read data. CTRL.RESET (reset) can land
// with reads in flight: bus_reset alone clears the in-flight count, and beats that
// arrive for a request reset abandoned are dropped
module weight_reader #(
    parameter int ARRAY_SIZE = 8,
    parameter int FIFO_DEPTH = 256,          // 16-byte beats
    parameter int BURST      = 16            // beats per burst, at most
) (
    input  logic                    clk,
    input  logic                    reset,                       // CTRL.RESET or power-on
    input  logic                    bus_reset,                   // power-on only

    input  logic                    request_valid_in,            // a pulse: read beats from address
    input  logic [31:0]             request_address_in,          // byte address, 16-byte aligned
    input  logic [31:0]             request_beats_in,

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
        if (128 % ROW_BITS != 0) $fatal(1, "weight_reader: a %0d-bit row must divide a 128-bit beat", ROW_BITS);
        if (BURST < 1 || BURST > 128 || BURST > FIFO_DEPTH) $fatal(1, "weight_reader: BURST=%0d", BURST);
    end

    // -- command side ---------------------------------------------------------------
    logic [31:0]            next_address, beats_to_issue;
    logic [7:0]             burst_beats;
    logic [COUNT_WIDTH-1:0] in_flight, discard, fifo_count;
    logic                   command_accepted, beat_kept;

    assign burst_beats = beats_to_issue < 32'(BURST) ? 8'(beats_to_issue) : 8'(BURST);
    // everything in flight lands in the FIFO, so it must fit alongside this burst
    assign memory_read_out       = !reset && beats_to_issue != 0 && discard == 0
                                   && 32'(fifo_count) + 32'(in_flight) + 32'(burst_beats) <= 32'(FIFO_DEPTH);
    assign memory_address_out    = next_address;
    assign memory_burstcount_out = burst_beats;
    assign command_accepted      = memory_read_out && !memory_waitrequest_in;
    assign beat_kept             = memory_readdatavalid_in && discard == 0 && !reset;

    always_ff @(posedge clk) begin
        if (bus_reset) begin
            in_flight <= '0;
            discard   <= '0;
        end else begin
            in_flight <= in_flight + (command_accepted ? COUNT_WIDTH'(burst_beats) : '0)
                                   - COUNT_WIDTH'(memory_readdatavalid_in);
            if (reset)
                discard <= in_flight - COUNT_WIDTH'(memory_readdatavalid_in);
            else if (memory_readdatavalid_in && discard != 0)
                discard <= discard - 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            next_address   <= '0;
            beats_to_issue <= '0;
        end else if (request_valid_in) begin
            next_address   <= request_address_in;
            beats_to_issue <= request_beats_in;
        end else if (command_accepted) begin
            next_address   <= next_address + {20'd0, burst_beats, 4'd0};
            beats_to_issue <= beats_to_issue - 32'(burst_beats);
        end
    end

    // -- prefetch FIFO and row unpacking ---------------------------------------
    logic         fifo_empty, fifo_full, beat_done;
    logic [127:0] beat;
    logic [$clog2(ROWS_PER_BEAT+1)-1:0] row_in_beat;

    assign beat_done = row_pop_in && row_valid_out && row_in_beat == ($bits(row_in_beat))'(ROWS_PER_BEAT - 1);

    block_fifo #(.WIDTH(128), .DEPTH(FIFO_DEPTH)) u_prefetch (
        .clk(clk), .reset(reset), .write_enable_in(beat_kept), .write_data_in(memory_readdata_in),
        .read_enable_in(beat_done), .read_data_out(beat), .full_out(fifo_full), .empty_out(fifo_empty));

    always_ff @(posedge clk) begin
        if (reset)
            fifo_count <= '0;
        else
            fifo_count <= fifo_count + COUNT_WIDTH'(beat_kept) - COUNT_WIDTH'(beat_done);
    end

    assign row_valid_out = !fifo_empty;
    assign row_data_out  = beat[ROW_BITS*row_in_beat +: ROW_BITS];

    always_ff @(posedge clk) begin
        if (reset || beat_done)
            row_in_beat <= '0;
        else if (row_pop_in && row_valid_out)
            row_in_beat <= row_in_beat + 1'b1;
    end

`ifndef SYNTHESIS
    // the credit check above makes overflow impossible
    always_ff @(posedge clk)
        if (!reset && beat_kept && fifo_full) $fatal(1, "weight_reader: prefetch FIFO overflow");
`endif

endmodule
